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

  # Each wait_for_healthcheck call polls every 3 minutes, so its budget is attempts * 3.
  let(:wait_budget_minutes) do
    DEPLOY_SCRIPT.read.scan(/wait_for_healthcheck\s+"[^"]+"\s+\S+\s+(\d+)\s+\w+/)
      .sum { |(attempts)| attempts.to_i * 3 }
  end

  it "parses the deploy step out of the pipeline" do
    expect(step).to be_present
    expect(step["command"]).to eq(".buildkite/scripts/deploy_production.sh")
  end

  it "finds every healthcheck wait in the deploy script" do
    # 15 attempts (payouts) + 40 attempts (long-running jobs), 3 minutes apart
    expect(wait_budget_minutes).to eq(165)
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
