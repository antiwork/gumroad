# frozen_string_literal: true

require "spec_helper"

describe "BugsnagHandleSidekiqRetriesCallback" do
  before do
    @callback = BugsnagHandleSidekiqRetriesCallback
  end

  it "ignores report when it is not the last job run attempt" do
    report = double(meta_data: { sidekiq: { msg: { "retry" => 1 } } })
    expect(report).to receive(:ignore!)
    @callback.call(report)

    report = double(meta_data: { sidekiq: { msg: { "retry" => 2, "retry_count" => 0 } } })
    expect(report).to receive(:ignore!)
    @callback.call(report)
  end

  it "does not ignore report it is the last job  run attempt" do
    # When retry = retry_count + 1, the job will go to the dead queue if it fails:
    # we want to notify bugsnag of errors at this point.
    report = double(meta_data: { sidekiq: { msg: { "retry" => 1, "retry_count" => 0 } } })
    expect(report).not_to receive(:ignore!)
    @callback.call(report)

    # retry_count is nil on the first attempt.
    # If this is the first attempt AND retry = 0, we don't want to ignore, as it's the last attempt.
    report = double(meta_data: { sidekiq: { msg: { "retry" => 0 } } })
    expect(report).not_to receive(:ignore!)
    @callback.call(report)
  end

  it "does not ignore report when 'retry' is not configured" do
    report = double(meta_data: { sidekiq: { msg: {} } })
    expect(report).not_to receive(:ignore!)
    @callback.call(report)
  end

  it "does not ignore report when it does not come from sidekiq" do
    report = double(meta_data: {})
    expect(report).not_to receive(:ignore!)
    @callback.call(report)
  end
end
