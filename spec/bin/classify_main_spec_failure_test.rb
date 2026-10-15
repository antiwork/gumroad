#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/classify-main-spec-failure.
#
# Plain ruby, no Rails, same as spec/bin/classify_hung_checkout_test.rb.
#
#   ruby spec/bin/classify_main_spec_failure_test.rb

require "json"
require "open3"
require "tempfile"
require "yaml"

CLASSIFIER = File.expand_path("../../bin/classify-main-spec-failure", __dir__)

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
    "head_branch" => "main"
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

# The workflow writes these in place of the summary when the shard log is
# missing, shows Knapsack in fallback mode, or never reached the end of its queue.
check(
  "a shard whose Knapsack ran in fallback mode",
  with_summary(attempt([job("Test Slow 12", "failure", SPEC_FAILURE)]), "knapsack fallback mode"),
  expect: :skip
)

check(
  "a shard whose log could not be fetched",
  with_summary(attempt([job("Test Slow 12", "failure", SPEC_FAILURE)]), "log unavailable"),
  expect: :skip
)

check(
  "a shard whose Knapsack queue did not finish",
  with_summary(attempt([job("Test Slow 12", "failure", SPEC_FAILURE)]), "knapsack queue did not finish"),
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

# An early deploy can ship a commit before its suite ends, so a flake on a commit
# that main has moved past still needs its retry before a revert reads it as final.
check(
  "a commit that is no longer main's tip",
  attempt(
    [job("Test Slow 34", "failure", SPEC_FAILURE)],
    head_sha: "8c49aff27d963e0453582662a153e9194715d36b", main_sha: "23e9dbef16a7d5e0d1d9a3cbf3a0b1d2c3e4f5a6"
  ),
  expect: :rerun
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

# --spec-failed feeds the revert verdict: only failing tests in a shard's test
# step say something about the code; a timeout fails the step without a summary.
def spec_failed_with(jobs, summary)
  payload = attempt(jobs)
  payload["summaries"] = jobs.to_h { |j| [j["id"].to_s, summary] }
  payload
end

{
  "an rspec shard with failing examples" => [[job("Test Slow 12", "failure", SPEC_FAILURE)], "45 examples, 1 failure", "true"],
  "an rspec shard with an error outside examples" => [[job("Test Slow 12", "failure", SPEC_FAILURE)], "0 examples, 0 failures, 1 error occurred outside of examples", "true"],
  "a minitest shard with failures" => [[job("Test Minitest 1", "failure", MINITEST_FAILURE)], "1342 runs, 4447 assertions, 1 failures, 0 errors, 0 skips", "true"],
  "a minitest shard with errors" => [[job("Test Minitest 1", "failure", MINITEST_FAILURE)], "1342 runs, 4447 assertions, 0 failures, 2 errors, 0 skips", "true"],
  # A timeout and a load error that stopped the runner both leave no summary.
  "a test step with no summary" => [[job("Test Slow 12", "failure", SPEC_FAILURE)], "", "null"],
  "a minitest step with no summary" => [[job("Test Minitest 1", "failure", MINITEST_FAILURE)], "", "null"],
  "a shard that hit its job time limit in its test step" => [[job("Test Minitest 1", "timed_out", [["Check out repository", "success"], ["Run Minitest", "cancelled"]])], "", "null"],
  "a time-limited shard next to real failures" => [[job("Test Slow 12", "failure", SPEC_FAILURE), job("Test Minitest 1", "timed_out", [["Run Minitest", "cancelled"]])], "45 examples, 1 failure", "true"],
  "a shard that timed out before its test step" => [[job("Test Slow 12", "timed_out", [["Check out repository", "cancelled"], ["Run tests", "skipped"]])], "", "false"],
  "a summary with no failures" => [[job("Test Slow 12", "failure", SPEC_FAILURE)], "45 examples, 0 failures", "false"],
  "a hung checkout" => [[job("Test Slow 3", "failure", HUNG_CHECKOUT)], "45 examples, 1 failure", "false"],
  "a failed build job" => [[job("Build images", "failure", [["Build test image", "failure"]])], "45 examples, 1 failure", "false"],
  "only cancelled shards" => [[job("Test Fast 11", "cancelled", SPEC_CANCELLED)], "45 examples, 1 failure", "false"]
}.each do |name, (jobs, summary, expected)|
  $count += 1
  _, printed = run(JSON.dump(spec_failed_with(jobs, summary)), "--spec-failed")
  if printed.strip == expected
    puts "  ok    --spec-failed: #{name}"
  else
    puts "  FAIL  --spec-failed: #{name}"
    $failures << "--spec-failed #{name}: expected #{expected}, got #{printed.strip.inspect}"
  end
end

# --card-declined tells the revert verdict that the shared Stripe test card was
# declined across shards, which no commit causes on its own.
def declined_shards(declined, other: 0, steps: SPEC_FAILURE)
  declined_jobs = Array.new(declined) { |index| job("Test Slow #{index}", "failure", steps) }
  other_jobs = Array.new(other) { |index| job("Test Fast #{index}", "failure", SPEC_FAILURE) }
  attempt(declined_jobs + other_jobs, declines: declined_jobs.to_h { |j| [j["id"].to_s, true] })
end

{
  "three shards that declined the test card" => [declined_shards(3), "true"],
  "two shards that declined the test card, which a retry covers" => [declined_shards(2), "false"],
  "declines in a minority of the red shards" => [declined_shards(3, other: 4), "false"],
  "declines in most of the red shards" => [declined_shards(4, other: 3), "true"],
  "declines in shards that never reached their tests" => [declined_shards(3, steps: HUNG_CHECKOUT), "false"],
  "a verdict input without declines" => [attempt(Array.new(3) { job("Test Slow 1", "failure", SPEC_FAILURE) }), "false"]
}.each do |name, (payload, expected)|
  $count += 1
  _, printed = run(JSON.dump(payload), "--card-declined")
  if printed.strip == expected
    puts "  ok    --card-declined: #{name}"
  else
    puts "  FAIL  --card-declined: #{name}"
    $failures << "--card-declined #{name}: expected #{expected}, got #{printed.strip.inspect}"
  end
end

# --declined-log reads one shard log. A blocked card is what a failed check
# found; a spec that expects the decline prints it on the expected side.
{
  "an alert check that found the decline" =>
    [%(expected to find alert with text "Your purchase was successful!" but there were no matches. Also found "", "Your card was declined."), "true"],
  "a text check that found the decline" =>
    [%(expected to find text "Your purchase was successful!" in "Checkout\\nYour card was declined."), "true"],
  "a colored eq failure that got the decline" => [%(\e[31m     got: "Your card was declined."\e[0m), "true"],
  "an alert check that expected the decline" =>
    [%(expected to find alert with text "Your card was declined." but there were no matches. Also found "Your purchase was successful!"), "false"],
  "an eq failure that expected the decline" => [%(     expected: "Your card was declined."\n          got: "Your purchase was successful!"), "false"],
  "the failing source line" => [%(Failure/Error: expect(page).to have_alert(text: "Your card was declined.")), "false"],
  "a log without the decline" => ["45 examples, 1 failure", "false"]
}.each do |name, (log, expected)|
  $count += 1
  printed = Tempfile.create(["shard", ".log"]) do |file|
    file.write(log)
    file.flush
    run("", "--declined-log", file.path).last
  end
  if printed.strip == expected
    puts "  ok    --declined-log: #{name}"
  else
    puts "  FAIL  --declined-log: #{name}"
    $failures << "--declined-log #{name}: expected #{expected}, got #{printed.strip.inspect}"
  end
end

# --chromedriver-log reads one raw shard log, timestamps and colors included. Only
# a log whose every failure is a refused ChromeDriver connection counts.
def stamped(text)
  text.lines.map { |line| "2026-10-15T19:46:21.8260503Z #{line}" }.join
end

def rspec_failure(number, error)
  <<~LOG
    \e[31m  #{number}) Product page shows the price\e[0m
         Failure/Error: visit short_link_path(product)

         #{error}
         # /bundle_path/ruby/3.4.0/gems/capybara-3.40.0/lib/capybara/session.rb:281:in 'Capybara::Session#visit'
         # ./spec/support/capybara_helpers.rb:36:in 'CapybaraHelpers#visit'
  LOG
end

REFUSED = "Errno::ECONNREFUSED:\n       Failed to open TCP connection to 127.0.0.1:9515 (Connection refused - connect(2) for \"127.0.0.1\" port 9515)"
# rspec-retry groups each try of an example under one number.
RETRIED_REFUSED = <<~LOG
  2) Product page shows the tax
     Got 0 failures and 2 other errors:

     2.1) Failure/Error: super

          Errno::ECONNREFUSED:
            Failed to open TCP connection to 127.0.0.1:9515 (Connection refused - connect(2) for "127.0.0.1" port 9515)
          # /bundle_path/ruby/3.4.0/gems/timeout-0.6.1/lib/timeout.rb:296:in 'block in Timeout.timeout'
          # Errno::ECONNREFUSED:
          #   Connection refused - connect(2) for "127.0.0.1" port 9515

     2.2) Failure/Error: super

          Errno::ECONNREFUSED:
            Failed to open TCP connection to 127.0.0.1:9515 (Connection refused - connect(2) for "127.0.0.1" port 9515)
          # /bundle_path/ruby/3.4.0/gems/timeout-0.6.1/lib/timeout.rb:296:in 'block in Timeout.timeout'
LOG
FINISHED = "Finished in 3 minutes 51.7 seconds (files took 11.51 seconds to load)\n144 examples, 72 failures\n"
EXPECTATION = "expected to find text \"$10\" in \"Product\""
# A real failure whose cause chain mentions the refused connection: only the
# error above the backtrace counts.
CAUSED_BY_REFUSED = "#{EXPECTATION}\n     # ./spec/requests/product_spec.rb:12\n     # ------------------\n     # --- Caused by: ---\n     # Errno::ECONNREFUSED:\n     #   127.0.0.1:9515"

{
  "every failure lost ChromeDriver" => [stamped("Failures:\n\n#{rspec_failure(1, REFUSED)}\n#{RETRIED_REFUSED}\n#{FINISHED}"), "true"],
  "one real failure among refused ones" => [stamped("Failures:\n\n#{rspec_failure(1, REFUSED)}\n#{rspec_failure(2, EXPECTATION)}\n#{FINISHED}"), "false"],
  "a real failure whose cause mentions ChromeDriver" => [stamped("Failures:\n\n#{rspec_failure(1, CAUSED_BY_REFUSED)}\n#{FINISHED}"), "false"],
  "a refused connection to another port" => [stamped("Failures:\n\n#{rspec_failure(1, REFUSED.gsub('9515', '6379'))}\n#{FINISHED}"), "false"],
  "a refused connection outside the failure list" => [stamped("#{REFUSED}\n#{FINISHED}"), "false"],
  "a failure list with no failures in it" => [stamped("Failures:\n\n#{FINISHED}"), "false"],
  # The runner died while it printed the list: later failures are unknown.
  "a failure list that stops before it ends" => [stamped("Failures:\n\n#{rspec_failure(1, REFUSED)}"), "false"]
}.each do |name, (log, expected)|
  $count += 1
  printed = Tempfile.create(["shard", ".log"]) do |file|
    file.write(log)
    file.flush
    run("", "--chromedriver-log", file.path).last
  end
  if printed.strip == expected
    puts "  ok    --chromedriver-log: #{name}"
  else
    puts "  FAIL  --chromedriver-log: #{name}"
    $failures << "--chromedriver-log #{name}: expected #{expected}, got #{printed.strip.inspect}"
  end
end

# --chromedriver-down tells the revert verdict that a dead driver, not the code,
# failed every shard that failed in its test step.
def chromedriver_shards(refused:, other: [])
  refused_jobs = Array.new(refused) { |index| job("Test Slow #{index}", "failure", SPEC_FAILURE) }
  payload = attempt(refused_jobs + other, chromedriver: refused_jobs.to_h { |j| [j["id"].to_s, true] })
  payload["summaries"].merge!(other.to_h { |j| [j["id"].to_s, "1342 runs, 4447 assertions, 1 failures, 0 errors, 0 skips"] }) if other.any?
  payload
end

{
  "one shard that lost ChromeDriver" => [chromedriver_shards(refused: 1), "true"],
  "three shards that lost ChromeDriver" => [chromedriver_shards(refused: 3), "true"],
  "a lost ChromeDriver next to a real failure" => [chromedriver_shards(refused: 1, other: [job("Test Minitest 1", "failure", MINITEST_FAILURE)]), "false"],
  "a lost ChromeDriver next to a shard that never reached its tests" =>
    [chromedriver_shards(refused: 1, other: [job("Test Slow 3", "failure", HUNG_CHECKOUT)]), "true"],
  # Nothing shows what failed a shard with no summary, or one that timed out.
  "a shard whose refused log has no summary" =>
    [chromedriver_shards(refused: 1).tap { |p| p["summaries"].transform_values! { "" } }, "false"],
  "a lost ChromeDriver next to a timed-out shard" =>
    [chromedriver_shards(refused: 1, other: [job("Test Minitest 1", "timed_out", [["Run Minitest", "cancelled"]])]), "false"],
  "a verdict input without ChromeDriver answers" => [attempt([job("Test Slow 1", "failure", SPEC_FAILURE)]), "false"],
  "no shard that reported failing tests" => [attempt([job("Test Slow 3", "failure", HUNG_CHECKOUT)], chromedriver: {}), "false"]
}.each do |name, (payload, expected)|
  $count += 1
  _, printed = run(JSON.dump(payload), "--chromedriver-down")
  if printed.strip == expected
    puts "  ok    --chromedriver-down: #{name}"
  else
    puts "  FAIL  --chromedriver-down: #{name}"
    $failures << "--chromedriver-down #{name}: expected #{expected}, got #{printed.strip.inspect}"
  end
end

$count += 1
listed_jobs = [job("Test Slow 12", "failure", SPEC_FAILURE), job("Test Minitest 1", "failure", MINITEST_FAILURE), job("Test Slow 3", "failure", HUNG_CHECKOUT)]
_, listed = run(JSON.dump(attempt(listed_jobs)), "--test-step-failures")
if listed.split.map(&:to_i) == listed_jobs.first(2).map { |j| j["id"] }
  puts "  ok    --test-step-failures lists the shards that failed in their test step"
else
  puts "  FAIL  --test-step-failures lists the shards that failed in their test step"
  $failures << "--test-step-failures: got #{listed.strip.inspect}"
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

# In a shared main lane, a re-run would replace another commit's pending run.
$count += 1
group = YAML.load_file(TESTS_WORKFLOW).fetch("concurrency").fetch("group").to_s
if group.include?("github.ref == 'refs/heads/main' && format('-{0}', github.sha)")
  puts "  ok    tests.yml gives each main commit its own concurrency lane"
else
  puts "  FAIL  tests.yml gives each main commit its own concurrency lane"
  $failures << "tests.yml concurrency group: #{group.inspect}"
end

# Separate lanes let an older commit's suite pass after a newer commit shipped
# it; the unblock script must then leave the older build alone.
$count += 1
unblock = YAML.load_file(TESTS_WORKFLOW).fetch("jobs").fetch("unblock_deployment_from_buildkite").fetch("steps")
                .find { |step| step["name"] == "Unblock corresponding Buildkite build" }
script = File.read(File.expand_path("../../bin/unblock-buildkite-deploy", __dir__))
if unblock.dig("with", "command").to_s.include?("bin/unblock-buildkite-deploy") &&
   script.include?("compare/$COMMIT_SHA...production-release") && script.include?("ahead|identical)")
  puts "  ok    the unblock skips a commit that production already contains"
else
  puts "  FAIL  the unblock skips a commit that production already contains"
  $failures << "unblock step: missing the production check"
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
