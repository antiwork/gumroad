#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/revert-red-main-decision and its workflow.
#
#   ruby spec/bin/revert_red_main_decision_test.rb

require "json"
require "open3"
require "tempfile"
require "yaml"

DECISION = File.expand_path("../../bin/revert-red-main-decision", __dir__)

$failures = []
$count = 0

RED_RUN = { "id" => 37404168421, "head_sha" => "f69c0d04c4960000000000000000000000000000", "status" => "completed",
            "conclusion" => "failure", "event" => "push", "head_branch" => "main", "run_attempt" => 2,
            "display_title" => "Fix the café — checkout" }.freeze

def payload(run: RED_RUN, production: "ahead", gate_unblocked: true)
  { "run" => run, "production" => production, "gate_unblocked" => gate_unblocked }
end

# As the workflow calls it: a file argument, under a C locale.
def run(input)
  Tempfile.create(["decision", ".json"]) do |file|
    file.write(input)
    file.flush
    stdout, stderr, status = Open3.capture3({ "LC_ALL" => "C", "LANG" => "C" }, "ruby", DECISION, file.path)
    [status.exitstatus, stdout + stderr]
  end
end

def check(name, input, expect:, reason: nil)
  $count += 1
  code, output = run(input.is_a?(String) ? input : JSON.dump(input))
  actual = { 0 => :revert, 1 => :skip, 2 => :error }.fetch(code, :"exit #{code}")
  if actual == expect && (reason.nil? || output.include?("reason=#{reason}"))
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}\n    expected #{expect}#{" (#{reason})" if reason}, got #{actual}\n    #{output.strip}"
  end
end

puts "revert-red-main-decision"

check("a failed commit that production contains", payload, expect: :revert, reason: "shipped")
check("a failed commit that production is at", payload(production: "identical"), expect: :revert, reason: "shipped")
check("a failed commit whose deploy is running", payload(production: "behind", gate_unblocked: true), expect: :revert, reason: "shipping")
check("a failed commit that never deployed", payload(production: "behind", gate_unblocked: false), expect: :skip, reason: "not_deployed")
check("diverged history and a closed gate", payload(production: "diverged", gate_unblocked: false), expect: :skip, reason: "not_deployed")

# Read after the retry decision: a started retry decides on its own completion.
check("a retry is running", payload(run: RED_RUN.merge("status" => "in_progress", "conclusion" => nil)), expect: :skip, reason: "retry_in_progress")
check("the retry passed", payload(run: RED_RUN.merge("conclusion" => "success")), expect: :skip, reason: "not_failed")
check("a cancelled run", payload(run: RED_RUN.merge("conclusion" => "cancelled")), expect: :skip, reason: "not_failed")
check("a pull request run", payload(run: RED_RUN.merge("event" => "pull_request_target")), expect: :skip, reason: "not_main_push")
check("a push to another branch", payload(run: RED_RUN.merge("head_branch" => "feature")), expect: :skip, reason: "not_main_push")

check("an unknown production state", payload(production: ""), expect: :error, reason: "unknown_production_state")
check("no run", payload(run: nil), expect: :error)
check("input that is not JSON", "not json", expect: :error)
check("input that is not an object", "[]", expect: :error)

# --- The workflow ----------------------------------------------------------

WORKFLOW = YAML.load_file(File.expand_path("../../.github/workflows/revert-red-main-deploy.yml", __dir__))

def workflow_check(name, ok, detail)
  $count += 1
  if ok
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}: #{detail}"
  end
end

job = WORKFLOW.dig("jobs", "revert")
gate = job["if"].to_s
workflow_check(
  "the workflow runs only for a failed main push",
  ["conclusion == 'failure'", "event == 'push'", "head_branch == 'main'"].all? { |part| gate.include?(part) },
  gate.inspect
)

steps = job["steps"]
step = ->(name) { steps.find { |s| s["name"] == name } }

decide = step.call("Decide")["run"].to_s
workflow_check(
  "a first failure waits for the retry workflow before deciding",
  decide.include?('if [ "$ATTEMPT" = "1" ]') && decide.include?("rerun-main-spec-failure.yml/runs") &&
    decide.index("rerun-main-spec-failure.yml/runs") < decide.index("actions/runs/${RUN_ID}"),
  "Decide step"
)

revert = step.call("Open the revert PR")
workflow_check(
  "the revert PR is opened with gumclaw's token",
  revert.dig("env", "GH_TOKEN").to_s.include?("secrets.GUMCLAW_GITHUB_PAT"),
  revert["env"].inspect
)

# The step that holds gumclaw's token must not run anything from the repo.
workflow_check(
  "the token step runs no repo script",
  !revert["run"].to_s.match?(%r{(^|\s)(\./|bin/|script/|ruby |bash |sh )}),
  "Open the revert PR runs a repo script"
)

tell = step.call("Tell the original PR")
workflow_check(
  "the original PR hears about it even when the revert step fails",
  tell["if"].to_s.include?("!cancelled()") && tell.dig("env", "GH_TOKEN").to_s.include?("github.token"),
  tell["if"].inspect
)

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
