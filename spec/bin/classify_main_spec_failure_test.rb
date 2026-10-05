#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/classify-main-spec-failure.
#
# Plain ruby, no Rails, same as spec/bin/classify_hung_checkout_test.rb.
#
#   ruby spec/bin/classify_main_spec_failure_test.rb

require "json"
require "open3"
require "yaml"

CLASSIFIER = File.expand_path("../../bin/classify-main-spec-failure", __dir__)
MAIN_SHA = "2b00057fe05db4549704188b58a46a7217bd1728"

$failures = []
$count = 0

def job(name, conclusion, steps)
  @next_id = (@next_id || 100) + 1
  built = steps.each_with_index.map do |(step_name, step_conclusion), index|
    { "name" => step_name, "number" => index + 1, "status" => "completed", "conclusion" => step_conclusion }
  end
  { "id" => @next_id, "name" => name, "conclusion" => conclusion, "steps" => built }
end

# Every red Fast/Slow shard gets an example-failure summary unless a check
# overrides `summaries`.
def attempt(jobs, **overrides)
  summaries = jobs.each_with_object({}) do |job, all|
    all[job["id"].to_s] = "45 examples, 1 failure" if job["conclusion"] == "failure" && job["name"].match?(/\ATest (Fast|Slow) /)
  end
  {
    "jobs" => jobs,
    "summaries" => summaries,
    "conclusion" => "failure",
    "event" => "push",
    "head_branch" => "main",
    "head_sha" => MAIN_SHA,
    "main_sha" => MAIN_SHA
  }.merge(overrides.transform_keys(&:to_s))
end

def run(input, *argv)
  stdout, stderr, status = Open3.capture3("ruby", CLASSIFIER, *argv, stdin_data: input)
  [status.exitstatus, stdout + stderr]
end

def check(name, payload, expect:)
  $count += 1
  code, output = run(payload.is_a?(String) ? payload : JSON.dump(payload))
  # Exact codes: the workflow re-runs on 0 only, and 2 must never read as 0.
  actual = { 0 => :rerun, 1 => :skip, 2 => :error }.fetch(code, :"exit #{code}")
  if actual == expect
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}\n    expected #{expect}, got #{actual}\n    #{output.strip}"
  end
end

puts "classify-main-spec-failure"

SPEC_FAILURE = [["Check out repository", "success"], ["Run tests", "failure"]].freeze
SPEC_CANCELLED = [["Check out repository", "success"], ["Run tests", "cancelled"]].freeze
PASSED = [["Check out repository", "success"], ["Run tests", "success"]].freeze
HUNG_CHECKOUT = [["Check out repository", "failure"], ["Run tests", "skipped"]].freeze
MINITEST_FAILURE = [["Check out repository", "success"], ["Run Minitest", "failure"]].freeze

check(
  "one slow shard failed in Run tests",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE), job("Test Slow 13", "success", PASSED)]),
  expect: :rerun
)

check(
  "one minitest shard failed in Run Minitest",
  attempt([job("Test Minitest 1", "failure", MINITEST_FAILURE)]),
  expect: :rerun
)

check(
  "a minitest shard that failed outside Run Minitest",
  attempt([job("Test Minitest 1", "failure", SPEC_FAILURE)]),
  expect: :skip
)

# Knapsack gives a re-run of a cancelled shard none of its unrun tests, so the
# retry would pass without running them.
check(
  "a fast shard failed and its siblings were cancelled",
  attempt([
            job("Test Fast 10", "failure", SPEC_FAILURE),
            job("Test Fast 11", "cancelled", SPEC_CANCELLED),
            job("Test Fast 12", "cancelled", SPEC_CANCELLED)
          ]),
  expect: :skip
)

def with_summary(payload, summary)
  payload["summaries"].transform_values! { summary }
  payload
end

check(
  "a summary with pending examples",
  with_summary(attempt([job("Test Fast 10", "failure", SPEC_FAILURE)]), "2045 examples, 1 failure, 3 pending"),
  expect: :rerun
)

# The retry re-runs failed examples only; a hook or load error has none.
check(
  "an error outside of examples",
  with_summary(attempt([job("Test Slow 12", "failure", SPEC_FAILURE)]), "45 examples, 0 failures, 1 error occurred outside of examples"),
  expect: :skip
)

check(
  "failures plus an error outside of examples",
  with_summary(attempt([job("Test Slow 12", "failure", SPEC_FAILURE)]), "45 examples, 1 failure, 1 error occurred outside of examples"),
  expect: :skip
)

check(
  "a summary with no failures",
  with_summary(attempt([job("Test Slow 12", "failure", SPEC_FAILURE)]), "0 examples, 0 failures"),
  expect: :skip
)

check(
  "a failed rspec shard with no summary",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE)], summaries: {}),
  expect: :skip
)

check(
  "two failed shards is the limit",
  attempt([job("Test Fast 10", "failure", SPEC_FAILURE), job("Test Slow 3", "failure", SPEC_FAILURE)]),
  expect: :rerun
)

check(
  "three failed shards reads as a real break",
  attempt([
            job("Test Fast 10", "failure", SPEC_FAILURE),
            job("Test Slow 3", "failure", SPEC_FAILURE),
            job("Test Slow 4", "failure", SPEC_FAILURE)
          ]),
  expect: :skip
)

# The run that holds production is the tip's run; an older commit already ships
# in the newer one.
check(
  "the commit is no longer main's tip",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE)], main_sha: "4eca2d9d310fe71dc3e9b53113ecd6aa40a92f55"),
  expect: :skip
)

check(
  "a missing head sha",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE)], head_sha: ""),
  expect: :skip
)

check(
  "a pull request run",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE)], event: "pull_request_target", head_branch: "some-branch"),
  expect: :skip
)

check(
  "a push to another branch",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE)], head_branch: "gianfranco/feature"),
  expect: :skip
)

# Someone cancelled the run after a shard had already failed; the job list alone
# would read as a rerun.
check(
  "a cancelled run with a failed shard",
  attempt(
    [job("Test Slow 12", "failure", SPEC_FAILURE), job("Test Slow 13", "cancelled", SPEC_CANCELLED)],
    conclusion: "cancelled"
  ),
  expect: :skip
)

# The run conclusion alone says the run was thrown away.
check(
  "a cancelled run whose jobs show only a failed shard",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE), job("Test Slow 13", "success", PASSED)], conclusion: "cancelled"),
  expect: :skip
)

check(
  "a run that passed",
  attempt([job("Test Slow 12", "success", PASSED)], conclusion: "success"),
  expect: :skip
)

# rerun-hung-checkout.yml owns this one.
check(
  "a hung checkout on a shard",
  attempt([job("Test Slow 3", "failure", HUNG_CHECKOUT)]),
  expect: :skip
)

check(
  "a spec failure plus a hung checkout",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE), job("Test Slow 3", "failure", HUNG_CHECKOUT)]),
  expect: :skip
)

check(
  "a shard that timed out",
  attempt([job("Test Slow 12", "timed_out", [["Check out repository", "success"], ["Run tests", "cancelled"]])]),
  expect: :skip
)

check(
  "a failed build job",
  attempt([job("Build images", "failure", [["Check out repository", "success"], ["Build test image", "failure"]])]),
  expect: :skip
)

check(
  "a lint failure next to a spec failure",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE), job("Lint Ruby", "failure", [["Run rubocop", "failure"]])]),
  expect: :skip
)

check(
  "a relevant-specs shard",
  attempt([job("Test Relevant 2", "failure", SPEC_FAILURE)]),
  expect: :skip
)

check(
  "a cancelled non-shard job",
  attempt([job("Test Slow 12", "failure", SPEC_FAILURE), job("Build images", "cancelled", [["Build test image", "cancelled"]])]),
  expect: :skip
)

check(
  "only cancelled shards",
  attempt([job("Test Fast 11", "cancelled", SPEC_CANCELLED)]),
  expect: :skip
)

check(
  "a failed shard whose failing step is not Run tests",
  attempt([job("Test Fast 4", "failure", [["Check out repository", "success"], ["Log in to Docker Hub", "failure"], ["Run tests", "skipped"]])]),
  expect: :skip
)

check("a red attempt with no jobs", attempt([]), expect: :skip)
check("input that is not JSON", "not json", expect: :error)
check("input that is not an object", "[]", expect: :error)

# The workflow fetches a summary only for the ids this prints, so a shard it
# misses has no summary and is refused.
$count += 1
listed_jobs = [
  job("Test Fast 10", "failure", SPEC_FAILURE),
  job("Test Slow 12", "failure", SPEC_FAILURE),
  job("Test Slow 13", "success", PASSED),
  job("Test Minitest 1", "failure", MINITEST_FAILURE),
  job("Build images", "failure", [["Build test image", "failure"]])
]
_, listed = run(JSON.dump(attempt(listed_jobs)), "--rspec-shards")
if listed.split.map(&:to_i) == listed_jobs.first(2).map { |j| j["id"] }
  puts "  ok    --rspec-shards lists only the failed Fast and Slow shards"
else
  puts "  FAIL  --rspec-shards lists only the failed Fast and Slow shards"
  $failures << "--rspec-shards: got #{listed.strip.inspect}"
end

# --- The workflow's own gate ----------------------------------------------
#
# The attempt cap and the main-push scope live in the job `if`, which nothing
# above can reach.

WORKFLOW = File.expand_path("../../.github/workflows/rerun-main-spec-failure.yml", __dir__)

$count += 1
gate = YAML.load_file(WORKFLOW).fetch("jobs").fetch("rerun").fetch("if")
wanted = [
  "run_attempt < 2",
  "conclusion == 'failure'",
  "event == 'push'",
  "head_branch == 'main'"
]
if wanted.all? { |part| gate.include?(part) }
  puts "  ok    the workflow gate caps attempts and only runs on a failed main push"
else
  puts "  FAIL  the workflow gate caps attempts and only runs on a failed main push"
  $failures << "workflow gate: #{gate.inspect}"
end

TESTS_WORKFLOW = File.expand_path("../../.github/workflows/tests.yml", __dir__)

# A fail-fast cancel on main would leave every retry refused.
$count += 1
fail_fast = YAML.load_file(TESTS_WORKFLOW).fetch("jobs").fetch("test_fast").fetch("strategy").fetch("fail-fast").to_s
if fail_fast.include?("github.event_name != 'push'") && fail_fast.include?("github.ref != 'refs/heads/main'")
  puts "  ok    tests.yml test_fast does not fail fast on main pushes"
else
  puts "  FAIL  tests.yml test_fast does not fail fast on main pushes"
  $failures << "test_fast fail-fast: #{fail_fast.inspect}"
end

# The classifier matches job and step names from tests.yml; a rename there would
# turn every retry into a silent skip.
{ "test_fast" => ["Test Fast", "Run tests"], "test_slow" => ["Test Slow", "Run tests"], "test_minitest" => ["Test Minitest", "Run Minitest"] }.each do |key, (prefix, step)|
  $count += 1
  definition = YAML.load_file(TESTS_WORKFLOW).fetch("jobs").fetch(key)
  if definition.fetch("name").start_with?("#{prefix} ") && definition.fetch("steps").any? { |s| s["name"] == step }
    puts "  ok    tests.yml #{key} is named #{prefix.inspect} and has #{step.inspect}"
  else
    puts "  FAIL  tests.yml #{key} is named #{prefix.inspect} and has #{step.inspect}"
    $failures << "tests.yml #{key}: name #{definition['name'].inspect}"
  end
end

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
