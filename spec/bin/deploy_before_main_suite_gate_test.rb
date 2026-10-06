#!/usr/bin/env ruby
# frozen_string_literal: true

# Plain ruby, no Rails, like spec/bin/classify_main_spec_failure_test.rb.

require "json"
require "open3"
require "tempfile"
require "tmpdir"
require "yaml"

GATE = File.expand_path("../../bin/deploy-before-main-suite-gate", __dir__)
SHA = "fbf8836d0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

$failures = []
$count = 0

def run_record(id, sha, status, conclusion, created_at, attempt: 1, updated_at: created_at)
  { "id" => id, "head_sha" => sha, "status" => status, "conclusion" => conclusion,
    "created_at" => created_at, "updated_at" => updated_at, "run_attempt" => attempt }
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
  payload(runs: [OWN_RUN, run_record(1, "older1", "completed", "failure", "2026-10-06T14:33:27Z"), run_record(0, "older0", "completed", "success", "2026-10-06T13:10:15Z")]),
  expect: :wait, reason: "frozen_main_red"
)

# The API order is not trusted; the finish time decides which run is newest.
check(
  "the newest run is listed last",
  payload(runs: [run_record(0, "older0", "completed", "success", "2026-10-06T13:10:15Z"), run_record(1, "older1", "completed", "failure", "2026-10-06T14:33:27Z")]),
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
  payload(runs: [OWN_RUN, run_record(2, "older2", "completed", "failure", "2026-10-06T14:40:00Z"), run_record(1, "older1", "completed", "success", "2026-10-06T14:50:00Z"),
                 run_record(2, "older2", "in_progress", nil, "2026-10-06T14:40:00Z", attempt: 2)]),
  expect: :wait, reason: "frozen_retry_in_progress"
)

check(
  "a passed retry wins over the failed first attempt",
  payload(runs: [OWN_RUN, run_record(2, "older2", "completed", "failure", "2026-10-06T14:50:00Z"),
                 run_record(2, "older2", "completed", "success", "2026-10-06T14:50:00Z", attempt: 2)]),
  expect: :early
)

check(
  "a cancelled retry of a failed run keeps the freeze",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS, run_record(2, "older2", "completed", "cancelled", "2026-10-06T14:50:00Z", attempt: 2)]),
  expect: :wait, reason: "frozen_main_red"
)

# The listed copy says in progress; the copy read again just before the
# decision says it failed.
check(
  "a run that finished red while the lists were read",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS,
                 run_record(2, "older2", "in_progress", nil, "2026-10-06T14:50:00Z", updated_at: "2026-10-06T15:05:00Z"),
                 run_record(2, "older2", "completed", "failure", "2026-10-06T14:50:00Z", updated_at: "2026-10-06T15:07:00Z")]),
  expect: :wait, reason: "frozen_main_red"
)

# A retry that finishes between the active-run listing and the fresh read: the
# unfinished copy must not count.
check(
  "a retry that finished green after it was listed as running",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS,
                 run_record(2, "older2", "in_progress", nil, "2026-10-06T14:50:00Z", attempt: 2, updated_at: "2026-10-06T15:05:00Z"),
                 run_record(2, "older2", "completed", "success", "2026-10-06T14:50:00Z", attempt: 2, updated_at: "2026-10-06T15:07:00Z")]),
  expect: :early
)

check(
  "a stale unfinished copy listed after the finished retry",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS,
                 run_record(2, "older2", "completed", "success", "2026-10-06T14:50:00Z", attempt: 2, updated_at: "2026-10-06T15:07:00Z"),
                 run_record(2, "older2", "in_progress", nil, "2026-10-06T14:50:00Z", attempt: 2, updated_at: "2026-10-06T15:05:00Z")]),
  expect: :early
)

check(
  "a retry that finished red after it was listed as running",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS,
                 run_record(2, "older2", "in_progress", nil, "2026-10-06T14:50:00Z", attempt: 2, updated_at: "2026-10-06T15:05:00Z"),
                 run_record(2, "older2", "completed", "failure", "2026-10-06T14:50:00Z", attempt: 2, updated_at: "2026-10-06T15:07:00Z")]),
  expect: :wait, reason: "frozen_main_red"
)

# An older run re-run to red after a newer run passed: its created_at is old,
# but it finished last.
check(
  "an older run re-run red after a newer run passed",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS,
                 run_record(3, "older3", "completed", "failure", "2026-10-06T10:00:00Z", attempt: 2, updated_at: "2026-10-06T15:00:00Z")]),
  expect: :wait, reason: "frozen_main_red"
)

check(
  "a re-run created weeks ago finished red after a newer run passed",
  payload(runs: [OWN_RUN, GREEN_PREVIOUS,
                 run_record(3, "ancient", "completed", "failure", "2026-09-10T10:00:00Z", attempt: 2, updated_at: "2026-10-06T15:00:00Z")]),
  expect: :wait, reason: "frozen_main_red"
)

check(
  "an older run re-run to green lifts the freeze",
  payload(runs: [OWN_RUN, run_record(1, "older1", "completed", "failure", "2026-10-06T14:33:27Z"),
                 run_record(3, "older3", "completed", "success", "2026-10-06T10:00:00Z", attempt: 2, updated_at: "2026-10-06T15:00:00Z")]),
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


# --- The wrapper -----------------------------------------------------------
#
# Runs bin/deploy-before-main-suite against a stub gh (and a GNU-style date) on
# PATH. The stub applies each call's real --jq filter to canned API answers, so
# the wrapper's queries, filters, and control flow all run.

WRAPPER = File.expand_path("../../bin/deploy-before-main-suite", __dir__)
WRAPPER_SHA = "75a2d8e4f44f0000000000000000000000000000"


GH_STUB = <<~'SH'
  #!/usr/bin/env bash
  path=""
  filter="."
  while [ $# -gt 0 ]; do
    case "$1" in
      api | --paginate) ;;
      --jq) shift; filter="$1" ;;
      *) path="$1" ;;
    esac
    shift
  done
  echo "$path" >> "$STUB_DIR/calls"
  case "$path" in
    *"created=>="*) fixture=recent ;;
    *"created="*)
      range="${path##*created=}"
      fixture="older_${range%%&*}"
      [ -f "$STUB_DIR/$fixture.json" ] || fixture=no_runs
      ;;
    *"status=in_progress"*) fixture=status_in_progress ;;
    *"status="*) fixture=no_runs ;;
    */actions/runs/*) fixture="run-${path##*/}" ;;
    */pulls) fixture=pulls ;;
    */status) fixture=status ;;
    *) echo "unexpected path $path" >&2; exit 1 ;;
  esac
  [ -f "$STUB_DIR/fail-$fixture" ] && { echo "HTTP 502" >&2; exit 1; }
  # gh --jq prints strings raw and everything else as JSON.
  jq -rc "$filter" "$STUB_DIR/$fixture.json"
SH

# `date -u -d "N days ago" +FMT` prints T-Nd, so each slice's bounds show in the
# recorded calls.
DATE_STUB = <<~'SH'
  #!/usr/bin/env bash
  while [ $# -gt 0 ]; do
    [ "$1" = "-d" ] && { shift; echo "T-${1%% *}d"; exit 0; }
    shift
  done
  exit 1
SH

def wrapper_run_record(id, sha, status, conclusion, created_at, updated_at, attempt: 1)
  { "id" => id, "head_sha" => sha, "status" => status, "conclusion" => conclusion,
    "created_at" => created_at, "updated_at" => updated_at, "run_attempt" => attempt }
end

WRAPPER_OWN = wrapper_run_record(9, WRAPPER_SHA, "in_progress", nil, "2026-10-06T17:17:22Z", "2026-10-06T17:17:31Z")
WRAPPER_GREEN = wrapper_run_record(1, "fbf8836d0", "completed", "success", "2026-10-06T14:55:22Z", "2026-10-06T15:11:59Z")
WRAPPER_PULLS = [{ "number" => 8194, "merged_at" => "2026-10-06T17:17:19Z", "merge_commit_sha" => WRAPPER_SHA, "head" => { "sha" => "headsha" } }].freeze

def run_wrapper(recent:, older: {}, in_progress: [], fail: [])
  Dir.mktmpdir do |dir|
    { "gh" => GH_STUB, "date" => DATE_STUB }.each do |name, body|
      File.write(File.join(dir, name), body)
      File.chmod(0o755, File.join(dir, name))
    end
    fixtures = {
      "recent" => { "workflow_runs" => recent },
      "status_in_progress" => { "workflow_runs" => in_progress },
      "no_runs" => { "workflow_runs" => [] },
      "pulls" => WRAPPER_PULLS,
      "status" => { "statuses" => [{ "context" => "ci/green", "state" => "success" }] }
    }
    older.each { |range, runs| fixtures["older_#{range}"] = { "workflow_runs" => runs } }
    (recent + older.values.flatten + in_progress).each { |run| fixtures["run-#{run['id']}"] = run }
    fixtures.each { |name, data| File.write(File.join(dir, "#{name}.json"), JSON.dump(data)) }
    fail.each { |name| File.write(File.join(dir, "fail-#{name}"), "") }
    env = { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "STUB_DIR" => dir, "GITHUB_REPOSITORY" => "o/r", "COMMIT_SHA" => WRAPPER_SHA }
    output, status = Open3.capture2e(env, "bash", WRAPPER)
    calls = File.exist?(File.join(dir, "calls")) ? File.read(File.join(dir, "calls")).lines(chomp: true) : []
    [status.exitstatus, output, calls]
  end
end

def wrapper_check(name, expect_code:, reason: nil, **fixtures)
  $count += 1
  code, output, = run_wrapper(**fixtures)
  if code == expect_code && (reason.nil? || output.include?(reason))
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}: expected exit #{expect_code}#{" with #{reason}" if reason}, got #{code}\n    #{output.strip}"
  end
end

puts
puts "deploy-before-main-suite (the wrapper, against a stub gh)"

wrapper_check("a current list with a green main", recent: [WRAPPER_OWN, WRAPPER_GREEN], expect_code: 0, reason: "decision=early")

wrapper_check(
  "a list without this commit's own run is stale",
  recent: [WRAPPER_GREEN], expect_code: 2, reason: "the list is stale"
)

# Created ten days ago, re-run today, red after the latest green run.
old_red_rerun = wrapper_run_record(3, "old", "completed", "failure", "2026-09-26T10:00:00Z", "2026-10-06T16:00:00Z", attempt: 2)
wrapper_check(
  "a red re-run of an older run freezes",
  recent: [WRAPPER_OWN, WRAPPER_GREEN], older: { "T-14d..T-7d" => [old_red_rerun] }, expect_code: 1, reason: "frozen_main_red"
)
wrapper_check(
  "a red re-run from the oldest slice freezes",
  recent: [WRAPPER_OWN, WRAPPER_GREEN], expect_code: 1, reason: "frozen_main_red",
  older: { "T-31d..T-28d" => [wrapper_run_record(6, "oldest", "completed", "failure", "2026-09-07T10:00:00Z", "2026-10-06T16:00:00Z", attempt: 2)] }
)

old_red_first_attempt = wrapper_run_record(4, "old", "completed", "failure", "2026-09-26T10:00:00Z", "2026-10-06T16:00:00Z")
wrapper_check(
  "a first attempt from the older slices is ignored",
  recent: [WRAPPER_OWN, WRAPPER_GREEN], older: { "T-14d..T-7d" => [old_red_first_attempt] }, expect_code: 0, reason: "decision=early"
)

old_rerun_running = wrapper_run_record(5, "old", "in_progress", nil, "2026-09-26T10:00:00Z", "2026-10-06T16:00:00Z", attempt: 2)
wrapper_check(
  "an active re-run of an older run freezes",
  recent: [WRAPPER_OWN, WRAPPER_GREEN], in_progress: [old_rerun_running], expect_code: 1, reason: "frozen_retry_in_progress"
)

wrapper_check("a failed request stops the decision", recent: [WRAPPER_OWN, WRAPPER_GREEN], fail: ["recent"], expect_code: 2)

$count += 1
_, _, calls = run_wrapper(recent: [WRAPPER_OWN, WRAPPER_GREEN])
windows = calls.filter_map { |path| path[/created=([^&]+)/, 1] }
expected = [">=T-7d", "T-14d..T-7d", "T-21d..T-14d", "T-28d..T-21d", "T-31d..T-28d"]
if windows == expected
  puts "  ok    the wrapper reads the recent week and four older slices"
else
  puts "  FAIL  the wrapper reads the recent week and four older slices"
  $failures << "created windows: #{windows.inspect}"
end

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
