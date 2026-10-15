#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for bin/revert-red-main-decision and its workflow.
#
#   ruby spec/bin/revert_red_main_decision_test.rb

require "json"
require "open3"
require "tempfile"
require "tmpdir"
require "yaml"

DECISION = File.expand_path("../../bin/revert-red-main-decision", __dir__)

$failures = []
$count = 0

RED_RUN = { "id" => 37404168421, "head_sha" => "f69c0d04c4960000000000000000000000000000", "status" => "completed",
            "conclusion" => "failure", "event" => "push", "head_branch" => "main", "run_attempt" => 2,
            "display_title" => "Fix the café — checkout" }.freeze

def payload(run: RED_RUN, spec_failed: true, attempt: 2, production: "ahead", deploying: true, retry_failed: false, error: nil, card_declined: false,
            chromedriver_down: false)
  { "run" => run,
    "verdict" => { "attempt" => attempt, "spec_failed" => spec_failed, "retry_failed" => retry_failed, "card_declined" => card_declined,
                   "chromedriver_down" => chromedriver_down, "error" => error },
    "production" => production, "deploying" => deploying }
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
  actual = { 0 => :revert, 1 => :skip, 2 => :error, 3 => :notify }.fetch(code, :"exit #{code}")
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
check("a failed commit whose deploy is running", payload(production: "behind", deploying: true), expect: :revert, reason: "shipping")
check("a failed commit that never deployed", payload(production: "behind", deploying: false), expect: :skip, reason: "not_deployed")
check("diverged history and no deploy", payload(production: "diverged", deploying: false), expect: :skip, reason: "not_deployed")

# Attempt 1 failed a spec; a manual attempt 2 then failed somewhere else.
check("the run moved to a newer attempt", payload(attempt: 1), expect: :skip, reason: "attempt_moved")

# Read after the retry decision: a started retry decides on its own completion.
check("a retry is running", payload(run: RED_RUN.merge("status" => "in_progress", "conclusion" => nil)), expect: :skip, reason: "retry_in_progress")
check("the retry passed", payload(run: RED_RUN.merge("conclusion" => "success")), expect: :skip, reason: "not_failed")
check("a cancelled run", payload(run: RED_RUN.merge("conclusion" => "cancelled")), expect: :skip, reason: "not_failed")
check("a pull request run", payload(run: RED_RUN.merge("event" => "pull_request_target")), expect: :skip, reason: "not_main_push")
check("a push to another branch", payload(run: RED_RUN.merge("head_branch" => "feature")), expect: :skip, reason: "not_main_push")

check("an infrastructure failure", payload(spec_failed: false), expect: :skip, reason: "no_spec_failure")

# A blocked shared test card fails every commit alike, so a revert would undo a good one.
check("a shipped commit whose shards declined the test card", payload(card_declined: true), expect: :notify, reason: "test_card_declined")
check("declined test cards on a commit that never deployed", payload(card_declined: true, production: "behind", deploying: false), expect: :skip, reason: "not_deployed")
check("a verdict from before card declines were recorded", payload(card_declined: nil), expect: :revert, reason: "shipped")
check("declined test cards in a verdict missing a spec answer", payload(card_declined: true, spec_failed: nil), expect: :notify, reason: "test_card_declined")

# A dead ChromeDriver fails every browser spec after it, whatever the code.
check("a shipped commit whose failures all lost ChromeDriver", payload(chromedriver_down: true), expect: :notify, reason: "chromedriver_down")
check("a lost ChromeDriver on a commit that never deployed", payload(chromedriver_down: true, production: "behind", deploying: false), expect: :skip, reason: "not_deployed")
check("a verdict from before ChromeDriver was recorded", payload(chromedriver_down: nil), expect: :revert, reason: "shipped")

# The commit shipped, but nothing confirms the failure is final: ask a person.
check("the retry request failed", payload(retry_failed: true), expect: :notify, reason: "retry_failed")
check("the verdict could not read the run", payload(spec_failed: nil, error: "could not read the log of job 1"), expect: :notify, reason: "verdict_incomplete")
check("a verdict with no spec answer", payload(spec_failed: nil), expect: :notify, reason: "verdict_incomplete")
check("Buildkite could not say whether it is deploying", payload(production: "behind", deploying: nil), expect: :notify, reason: "deploy_state_unknown")
check(
  "an infrastructure failure with an unknown deploy state",
  payload(production: "behind", deploying: nil, spec_failed: false), expect: :skip, reason: "not_deployed"
)
check("an unconfirmed failure that never deployed", payload(retry_failed: true, production: "behind", deploying: false), expect: :skip, reason: "not_deployed")
check("an unknown production state", payload(production: ""), expect: :error, reason: "unknown_production_state")
check("no run", payload(run: nil), expect: :error)
check("input that is not JSON", "not json", expect: :error)
check("input that is not an object", "[]", expect: :error)

# --- The workflow ----------------------------------------------------------

WORKFLOW = YAML.load_file(File.expand_path("../../.github/workflows/revert-red-main-deploy.yml", __dir__))
RETRY = YAML.load_file(File.expand_path("../../.github/workflows/rerun-main-spec-failure.yml", __dir__))

def workflow_check(name, ok, detail)
  $count += 1
  if ok
    puts "  ok    #{name}"
  else
    puts "  FAIL  #{name}"
    $failures << "#{name}: #{detail}"
  end
end

trigger = WORKFLOW[true] || WORKFLOW["on"]
workflow_check(
  "the workflow follows the retry workflow",
  trigger.dig("workflow_run", "workflows") == ["Rerun main spec failure"],
  trigger.inspect
)

jobs = WORKFLOW["jobs"]
token_jobs = jobs.select { |_, job| job.to_s.include?("GUMCLAW_GITHUB_PAT") }.keys
workflow_check("only the open job holds gumclaw's token", token_jobs == ["open"], token_jobs.inspect)

# A repo script in the token's job could plant a wrapper through GITHUB_PATH.
open_runs = jobs.dig("open", "steps").map { |step| step["run"].to_s }.join("\n")
workflow_check(
  "the open job runs no repo script",
  !open_runs.match?(%r{(^|\s)(\./|bin/|script/|ruby |bash |sh )}),
  "a repo script in the open job"
)
open_actions = jobs.dig("open", "steps").filter_map { |step| step["uses"] }
workflow_check("the open job uses only actions/checkout", open_actions.all? { |uses| uses.start_with?("actions/checkout@") }, open_actions.inspect)

decide_run = jobs.dig("decide", "steps").find { |step| step["name"] == "Decide" }["run"].to_s
# Without the artifact, the Tests run comes from the retry run's title, and a
# verdict marked missing still reaches the decision (and a notify).
workflow_check(
  "a missing verdict still reaches the decision",
  decide_run.include?('select(.name == "verdict")') && decide_run.include?("VERDICT_RUN_TITLE") &&
    decide_run.include?("spec_failed: null, error: $error"),
  "Decide step"
)
title = RETRY["run-name"].to_s
workflow_check(
  "the retry run's title names the Tests run and attempt",
  title.end_with?("for run ${{ github.event.workflow_run.id }} attempt ${{ github.event.workflow_run.run_attempt }}"),
  title.inspect
)

# The Decide step's own Buildkite filter, run against builds: later steps keep a
# build running after its deploy finished, so shipping is read from the deploy
# job, past an opened gate.
deploying_filter = decide_run[/\| jq --arg sha "\$sha" '(.+?)'\) \\/m, 1].to_s
def build_with(gate:, deploy:, shadow: nil)
  jobs = [{ "step_key" => "require-approval", "state" => gate }, { "step_key" => "production-deployment", "state" => deploy }]
  jobs << { "step_key" => "asset-cache-shadow", "state" => shadow } if shadow
  { "commit" => "abc", "state" => "running", "jobs" => jobs }
end
{
  "a closed gate with a waiting deploy job" => [[build_with(gate: "blocked", deploy: "waiting")], "false"],
  "an open gate with a deploy queued behind another" => [[build_with(gate: "unblocked", deploy: "limited")], "true"],
  "an open gate with a running deploy" => [[build_with(gate: "unblocked", deploy: "running")], "true"],
  "a finished deploy while the shadow step still runs" => [[build_with(gate: "unblocked", deploy: "finished", shadow: "running")], "false"],
  "another commit's deploy" => [[build_with(gate: "unblocked", deploy: "running").merge("commit" => "other")], "false"]
}.each do |name, (builds, expected)|
  out, status = Open3.capture2("jq", "--arg", "sha", "abc", deploying_filter, stdin_data: JSON.dump(builds))
  workflow_check("deploying: #{name}", !deploying_filter.empty? && status.success? && out.strip == expected, "got #{out.strip.inspect}")
end

tell = jobs["tell"]
workflow_check(
  "the original PR hears about it even when the open job fails",
  tell["if"].to_s.include?("!cancelled()") && tell.to_s.include?("github.token") && !tell.to_s.include?("GUMCLAW"),
  tell["if"].inspect
)

tell_run = tell["steps"].first["run"].to_s
workflow_check(
  "an unknown deploy state gets its own message",
  tell_run.include?('[ "$REASON" = "deploy_state_unknown" ]') && tell_run.include?("Please check the deploy"),
  "Tell the original PR"
)

workflow_check(
  "the original PR also hears about an unconfirmed failure",
  tell["if"].to_s.include?("needs.decide.outputs.notify == 'true'"),
  tell["if"].inspect
)

# The verdict keys the revert to the exact Tests run and attempt.
verdict = RETRY.dig("jobs", "verdict")
rerun_step = RETRY.dig("jobs", "rerun", "steps").find { |step| step["name"] == "Re-run the failed jobs" }
record = verdict["steps"].find { |step| step["name"] == "Record the verdict" }
# A deliberate skip (main moved) leaves the rerun job green; only a failed
# request counts as retry_failed.
workflow_check(
  "retry_failed needs the rerun job to have failed",
  record["run"].to_s.include?('[ "$RERUN_RESULT" = "failure" ]') && record.dig("env", "RERUN_RESULT").to_s.include?("needs.rerun.result"),
  "Record the verdict"
)
# A verdict that errors out leaves no artifact, and the revert workflow skips.
workflow_check(
  "the verdict step records errors instead of failing",
  !record["run"].to_s.include?("set -e") && record["run"].to_s.include?("error.txt") && record["env"].key?("RETRY_WANTED"),
  "Record the verdict"
)
workflow_check(
  "the verdict records whether ChromeDriver refused every failure",
  ["--chromedriver-log shard.raw", ".chromedriver[$id] = $refused", "--chromedriver-down verdict-input.json",
   "chromedriver_down: $chromedriver_down"].all? { |part| record["run"].to_s.include?(part) },
  "Record the verdict"
)
# A newer commit on main does not ship this one before its suite ends: an early
# deploy may already have shipped it, so its flake still needs the retry.
workflow_check(
  "the retry runs on a commit that main has moved past",
  !rerun_step["run"].to_s.include?("commits/main") && !RETRY.dig("jobs", "rerun", "steps").to_s.include?("main_sha"),
  rerun_step["run"].to_s
)
workflow_check(
  "the verdict records whether shards declined the test card",
  ["--declined-log shard.raw", ".declines[$id] = $declined", "'. + $shards[0]' jobs.json > verdict-input.json",
   "--card-declined verdict-input.json", "card_declined: $card_declined"].all? { |part| record["run"].to_s.include?(part) },
  "Record the verdict"
)
# Gumclaw forwards a github-actions comment only when it carries this marker, so
# render the comment as the step builds it.
card_line = tell_run.lines.each_cons(2).find { |condition, _| condition.include?('[ "$REASON" = "test_card_declined" ]') }&.last.to_s.strip
rendered, = Open3.capture2(
  { "PR_AUTHOR" => "author", "SHA" => "abc123", "RUN_URL" => "https://example.com/runs/1" },
  "bash", "-c", "set -euo pipefail; #{card_line}; printf '%s' \"$body\""
)
workflow_check(
  "the original PR hears that the test card was declined, and Gumclaw gets the recovery",
  rendered.start_with?("@author ") && rendered.include?("@gumclaw will check the block list") &&
    rendered.end_with?("\n\n<!-- gumclaw:test-card-decline sha=abc123 run=https://example.com/runs/1 -->"),
  rendered.inspect
)

# GitHub drops a job output that contains a secret's value, and the run URL holds
# the repository name, which is also the Buildkite pipeline slug. So the decide
# job passes the run id, and each consumer builds the URL.
decide_outputs = jobs.dig("decide", "outputs")
workflow_check(
  "the decide job passes the run id and no URL",
  decide_outputs["run_id"] == "${{ steps.decide.outputs.run_id }}" && decide_outputs.values.none? { |value| value.include?("url") } &&
    decide_run.include?('echo "run_id=${run_id}"') && !decide_run.include?("html_url"),
  decide_outputs.inspect
)
open_step = jobs.dig("open", "steps").find { |step| step["name"] == "Open the revert PR" }
url_line = 'RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${RUN_ID}"'
workflow_check(
  "the revert PR body links the run",
  open_step.dig("env", "RUN_ID") == "${{ needs.decide.outputs.run_id }}" &&
    open_step["run"].to_s.index(url_line).to_i.between?(1, open_step["run"].to_s.index("> body.md").to_i),
  open_step["env"].inspect
)

# Runs the whole step with a `gh` stub that prints the comment it would post.
def tell_comment(script, env)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, "gh"), "#!/usr/bin/env bash\nwhile [ $# -gt 0 ]; do [ \"$1\" = --body ] && printf '%s' \"$2\"; shift; done\n")
    File.chmod(0o755, File.join(dir, "gh"))
    base = { "PATH" => "#{dir}:#{ENV.fetch('PATH')}", "GITHUB_SERVER_URL" => "https://github.com", "GITHUB_REPOSITORY" => "antiwork/gumroad",
             "SHA" => "abc123", "RUN_ID" => "38794492890", "PR_NUMBER" => "8435", "PR_AUTHOR" => "author",
             "NOTIFY" => "", "REASON" => "", "OPENED" => "", "REVERT_URL" => "" }
    out, = Open3.capture2(base.merge(env), "bash", "-c", script)
    out
  end
end
RUN_LINK = "https://github.com/antiwork/gumroad/actions/runs/38794492890"
workflow_check(
  "the original PR hears where the run is",
  tell["steps"].first.dig("env", "RUN_ID") == "${{ needs.decide.outputs.run_id }}" &&
    tell_comment(tell_run, "OPENED" => "true", "REVERT_URL" => "https://github.com/antiwork/gumroad/pull/8440").include?("deployed: #{RUN_LINK}. A revert PR"),
  tell_comment(tell_run, "OPENED" => "true").inspect
)
chromedriver_comment = tell_comment(tell_run, "NOTIFY" => "true", "REASON" => "chromedriver_down")
workflow_check(
  "a lost ChromeDriver gets its own message",
  chromedriver_comment.start_with?("@author ") && chromedriver_comment.include?("ChromeDriver: #{RUN_LINK}.") &&
    chromedriver_comment.end_with?("Please re-run the failed jobs."),
  chromedriver_comment.inspect
)
workflow_check(
  "the retry workflow records whether it started a retry",
  verdict && verdict["if"].to_s.include?("always()") &&
    verdict["steps"].any? { |step| step.dig("with", "name") == "main-failure-verdict" } &&
    rerun_step["run"].to_s.index("gh run rerun").to_i < rerun_step["run"].to_s.index("retried=true").to_i,
  verdict.inspect
)

puts
if $failures.empty?
  puts "#{$count} checks passed."
  exit 0
end

warn "#{$failures.size} of #{$count} checks FAILED:\n\n"
$failures.each { |f| warn "  #{f}\n\n" }
exit 1
