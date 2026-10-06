#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/deploy-before-main-suite-gate.
#
# Plain ruby, no Rails, same as spec/bin/classify_main_spec_failure_test.rb.
#
#   ruby spec/bin/deploy_before_main_suite_gate_test.rb

require "json"
require "open3"
require "tempfile"
require "yaml"

GATE = File.expand_path("../../bin/deploy-before-main-suite-gate", __dir__)
SHA = "fbf8836d0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

$failures = []
$count = 0

def run_record(id, sha, status, conclusion, created_at, attempt: 1)
  { "id" => id, "head_sha" => sha, "status" => status, "conclusion" => conclusion,
    "created_at" => created_at, "run_attempt" => attempt }
end

GREEN_PREVIOUS = run_record(1, "older1", "completed", "success", "2026-10-06T14:33:27Z")
OWN_RUN = run_record(9, SHA, "in_progress", nil, "2026-10-06T14:55:22Z")
MERGED_PR = { "number" => 8189, "merged_at" => "2026-10-06T14:55:18Z", "merge_commit_sha" => SHA, "head" => { "sha" => "7a9d4b97f" } }.freeze

def payload(runs: [OWN_RUN, GREEN_PREVIOUS], pulls: [MERGED_PR], ci_green: "success", sha: SHA)
  { "sha" => sha, "runs" => runs, "pulls" => pulls, "ci_green" => ci_green }
end

# As the workflow calls it: a file argument, under a C locale like a bare runner.
def run(input)
  Tempfile.create(["gate", ".json"]) do |file|
    file.write(input)
    file.flush
    stdout, stderr, status = Open3.capture3({ "LC_ALL" => "C", "LANG" => "C" }, "ruby", GATE, file.path)
    [status.exitstatus, stdout + stderr]
  end
end

def check(name, input, expect:, reason: nil)
  $count += 1
  code, output = run(input.is_a?(String) ? input : JSON.dump(input))
  actual = { 0 => :early, 1 => :wait, 2 => :error }.fetch(code, :"exit #{code}")
  if actual == expect && (reason.nil? || output.include?("reason=#{reason}"))
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}\n    expected #{expect}#{" (#{reason})" if reason}, got #{actual}\n    #{output.strip}"
  end
end

puts "deploy-before-main-suite-gate"

check("the last main run passed and the PR is green", payload, expect: :early, reason: "early")

check(
  "the last main run failed",
  payload(runs: [OWN_RUN, run_record(1, "older1", "completed", "failure", "2026-10-06T14:33:27Z"), GREEN_PREVIOUS.merge("id" => 0, "created_at" => "2026-10-06T13:10:15Z")]),
  expect: :wait, reason: "frozen_main_red"
)

# The API order is not trusted; created_at decides which run is newest.
check(
  "the newest run is listed last",
  payload(runs: [GREEN_PREVIOUS.merge("id" => 0, "created_at" => "2026-10-06T13:10:15Z"), run_record(1, "older1", "completed", "failure", "2026-10-06T14:33:27Z")]),
  expect: :wait, reason: "frozen_main_red"
)

# A newer push evicts a pending main run; that says nothing about main.
check(
  "a cancelled newest run is ignored",
  payload(runs: [OWN_RUN, run_record(2, "older2", "completed", "cancelled", "2026-10-06T14:50:00Z"), GREEN_PREVIOUS]),
  expect: :early
)

check(
  "an older run still in its first attempt is ignored",
  payload(runs: [OWN_RUN, run_record(2, "older2", "in_progress", nil, "2026-10-06T14:50:00Z"), GREEN_PREVIOUS]),
  expect: :early
)

check(
  "a re-run of a failed main run is in progress",
  payload(runs: [OWN_RUN, run_record(2, "older2", "in_progress", nil, "2026-10-06T14:50:00Z", attempt: 2), GREEN_PREVIOUS]),
  expect: :wait, reason: "frozen_retry_in_progress"
)

check(
  "a re-run that passed lifts the freeze",
  payload(runs: [OWN_RUN, run_record(2, "older2", "completed", "success", "2026-10-06T14:50:00Z", attempt: 2)]),
  expect: :early
)

check(
  "this commit's own run does not count",
  payload(runs: [run_record(9, SHA, "completed", "success", "2026-10-06T14:55:22Z")]),
  expect: :wait, reason: "frozen_no_finished_run"
)

check("no main run in the window", payload(runs: []), expect: :wait, reason: "frozen_no_finished_run")

check(
  "this commit's own suite already failed",
  payload(runs: [run_record(9, SHA, "completed", "failure", "2026-10-06T14:55:22Z"), GREEN_PREVIOUS]),
  expect: :wait, reason: "own_suite_failed"
)

check(
  "this commit's own suite is being retried",
  payload(runs: [run_record(9, SHA, "in_progress", nil, "2026-10-06T14:55:22Z", attempt: 2), GREEN_PREVIOUS]),
  expect: :wait, reason: "own_retry_in_progress"
)

check(
  "this commit's own suite passed",
  payload(runs: [run_record(9, SHA, "completed", "success", "2026-10-06T14:55:22Z"), GREEN_PREVIOUS]),
  expect: :early
)

# Active runs are fetched separately and can repeat a recent run.
check(
  "the same run listed twice",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS, GREEN_PREVIOUS]),
  expect: :early
)

# The recent snapshot shows the failed run as finished; the active query, later,
# shows it re-running.
check(
  "a newer copy of a run shows its retry",
  payload(runs: [OWN_RUN, run_record(2, "older2", "completed", "failure", "2026-10-06T14:40:00Z"), GREEN_PREVIOUS.merge("created_at" => "2026-10-06T14:50:00Z"),
                 run_record(2, "older2", "in_progress", nil, "2026-10-06T14:40:00Z", attempt: 2)]),
  expect: :wait, reason: "frozen_retry_in_progress"
)

check(
  "a passed retry wins over the failed first attempt",
  payload(runs: [OWN_RUN, run_record(2, "older2", "completed", "failure", "2026-10-06T14:50:00Z"),
                 run_record(2, "older2", "completed", "success", "2026-10-06T14:50:00Z", attempt: 2)]),
  expect: :early
)

# An old run re-run today keeps its old created_at.
check(
  "a re-run of an old main run is in progress",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS, run_record(3, "ancient", "in_progress", nil, "2026-09-01T10:00:00Z", attempt: 2)]),
  expect: :wait, reason: "frozen_retry_in_progress"
)

check("no PR for the commit", payload(pulls: []), expect: :wait, reason: "no_merged_pr")

check(
  "an open PR that contains the commit",
  payload(pulls: [MERGED_PR.merge("merged_at" => nil)]),
  expect: :wait, reason: "no_merged_pr"
)

check(
  "a PR merged as a different commit",
  payload(pulls: [MERGED_PR.merge("merge_commit_sha" => "other")]),
  expect: :wait, reason: "no_merged_pr"
)

%w[pending failure error].each do |state|
  check("ci/green is #{state}", payload(ci_green: state), expect: :wait, reason: "pr_not_green")
end

check("ci/green is missing", payload(ci_green: ""), expect: :wait, reason: "pr_not_green")
check("no sha", payload(sha: ""), expect: :wait, reason: "no_sha")
# Commit messages in the runs payload are not ASCII.
check(
  "a payload with non-ASCII commit messages",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS.merge("display_title" => "Fix the caf\u00e9 \u2014 checkout")]),
  expect: :early
)

check("a malformed runs list", payload(runs: [nil]), expect: :error)
check("input that is not JSON", "not json", expect: :error)
check("input that is not an object", "[]", expect: :error)

# --- The workflow ----------------------------------------------------------

WORKFLOW = YAML.load_file(File.expand_path("../../.github/workflows/deploy-before-main-suite.yml", __dir__))

def workflow_check(name, ok, detail)
  $count += 1
  if ok
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}: #{detail}"
  end
end

# YAML reads the bare `on:` key as true.
trigger = WORKFLOW[true] || WORKFLOW["on"]
workflow_check("the workflow runs only on pushes to main", trigger == { "push" => { "branches" => ["main"] } }, trigger.inspect)

group = WORKFLOW.dig("concurrency", "group").to_s
workflow_check("each commit gets its own concurrency lane", group.include?("github.sha"), group.inspect)

steps = WORKFLOW.dig("jobs", "unblock", "steps")
command = steps.find { |step| step["name"] == "Unblock corresponding Buildkite build" }&.dig("with", "command").to_s
order = ["bin/unblock-buildkite-deploy --ready", "\nbin/deploy-before-main-suite\n", "0) bin/unblock-buildkite-deploy ;;"].map { |part| command.index(part) }
# The freeze must be decided after the gate is ready, right before the unblock.
workflow_check("the step polls, then decides, then unblocks", order.none?(&:nil?) && order == order.sort, order.inspect)
workflow_check(
  "a wait decision stops the early path without failing",
  command.include?(%q{1) echo "Waiting for this commit's own Tests run."; exit 0 ;;}),
  command
)

checkout = steps.find { |step| step["uses"].to_s.start_with?("actions/checkout") }
sparse = checkout&.dig("with", "sparse-checkout").to_s.split
workflow_check(
  "the checkout has every script the step calls",
  %w[bin/deploy-before-main-suite bin/deploy-before-main-suite-gate bin/unblock-buildkite-deploy].all? { |path| sparse.include?(path) },
  sparse.inspect
)

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
