# frozen_string_literal: true

require "spec_helper"
require "yaml"

# The deploy step's timeout and the waits inside deploy_production.sh are two numbers in two
# files that have to agree. On 2026-08-01 they did not: the long-running-job wait alone was
# budgeted the entire step timeout, so build #18755 sat through all 40 attempts and was killed
# 5 seconds before the script would have exited 0 on its own skip path. The step is designed to
# give up gracefully; it can only do that if it is allowed to outlive its own waiting.
RSpec.describe "Production deploy step timeout" do
  PIPELINE = Rails.root.join(".buildkite/pipeline.yml")
  DEPLOY_SCRIPT = Rails.root.join(".buildkite/scripts/deploy_production.sh")

  # median deploy runtime, per the concurrency_group comment on the same step
  DEPLOY_RUNTIME_MINUTES = 23

  let(:step) do
    YAML.safe_load_file(PIPELINE).fetch("steps")
      .find { _1.is_a?(Hash) && _1["key"] == "production-deployment" }
  end

  # Read the polling interval out of the script rather than restating it: hard-coding 3 minutes
  # here would let someone widen `sleep` in wait_for_healthcheck and leave this spec green while
  # the real wait budget silently outgrew the step timeout again — the exact drift this file exists
  # to catch, one level up.
  let(:poll_interval_minutes) do
    sleeps = DEPLOY_SCRIPT.read[/wait_for_healthcheck\(\).*?\n}/m].to_s.scan(/^\s*sleep\s+(\d+)\s*$/).flatten.map(&:to_i).uniq
    expect(sleeps.size).to eq(1), "expected one polling sleep inside wait_for_healthcheck, found #{sleeps.inspect}"
    sleeps.first / 60.0
  end

  let(:script) { DEPLOY_SCRIPT.read }

  # Calls in this script wrap across lines with a trailing backslash, which is NOT whitespace, so
  # match against a copy with continuations folded away. Scanning the raw text silently finds zero
  # long-running calls and passes every assertion below vacuously.
  let(:folded_script) { script.gsub(/\\\n\s*/, " ") }

  # The long-running blocker is entered more than once — the confirmation loop re-waits when the
  # blocker goes busy again after the parallel waits cleared. Its attempt count therefore is NOT a
  # literal at the call site; it is a shared budget variable the callers decrement. Sum the literal
  # attempt counts and add that declared budget once, because once is what it can cost in total.
  let(:literal_attempt_budget_minutes) do
    folded_script.scan(/wait_for_healthcheck\s+"[^"]+"\s+\S+\s+(\d+)\s+\w+/)
      .sum { |(attempts)| attempts.to_i * poll_interval_minutes }
  end

  let(:shared_long_running_budget_minutes) do
    declared = script[/^LONG_RUNNING_MAX_ATTEMPTS=(\d+)$/, 1]
    expect(declared).to be_present, "expected a declared LONG_RUNNING_MAX_ATTEMPTS in the deploy script"
    declared.to_i * poll_interval_minutes
  end

  let(:wait_budget_minutes) { literal_attempt_budget_minutes + shared_long_running_budget_minutes }

  it "parses the deploy step out of the pipeline" do
    expect(step).to be_present
    expect(step["command"]).to eq(".buildkite/scripts/deploy_production.sh")
  end

  it "reads the polling interval from the script instead of assuming it" do
    expect(poll_interval_minutes).to eq(3)
  end

  it "finds every healthcheck wait in the deploy script" do
    # 15 attempts (payouts, literal) + 40 attempts (long-running jobs, shared budget), 3 min apart
    expect(wait_budget_minutes).to eq(165)
  end

  # The teeth of the shared budget. Every entry into the long-running wait has to draw its attempt
  # count from LONG_RUNNING_ATTEMPTS_LEFT; a literal 40 at any of those call sites would mean each
  # confirmation round restarts from a full 120 minutes, which is 600 minutes of legal waiting in a
  # 240-minute step — build #18755's death, re-introduced behind a retry loop.
  it "spends the long-running wait from one shared budget, never a fresh one per round" do
    long_running_calls = folded_script.scan(/wait_for_healthcheck\s+"Long-running job"\s+\S+\s+(\S+)\s+\w+/).flatten
    expect(long_running_calls).not_to be_empty
    expect(long_running_calls.uniq).to eq(['"$LONG_RUNNING_ATTEMPTS_LEFT"'])
  end

  it "charges spent attempts back against the shared budget at every call site" do
    decrements = script.scan(/LONG_RUNNING_ATTEMPTS_LEFT=\$\(\(LONG_RUNNING_ATTEMPTS_LEFT - \w+\)\)/)
    long_running_calls = folded_script.scan(/wait_for_healthcheck\s+"Long-running job"/)
    expect(decrements.size).to eq(long_running_calls.size)
  end

  it "allows the script to finish waiting AND still deploy" do
    expect(step["timeout_in_minutes"]).to be > wait_budget_minutes + DEPLOY_RUNTIME_MINUTES
  end

  it "would have rejected the timeout that killed build #18755" do
    # The regression itself: 120 was less than the 165 minutes of waiting the script can do,
    # so the skip path was unreachable and a waited-out deploy always died red.
    expect(120).to be < wait_budget_minutes
  end
end
