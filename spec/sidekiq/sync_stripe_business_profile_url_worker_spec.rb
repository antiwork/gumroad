# frozen_string_literal: true

require "spec_helper"

describe SyncStripeBusinessProfileUrlWorker do
  it "hands jobs queued under the old name to SyncStripeBusinessProfileUrlJob" do
    described_class.new.perform(123, "oldusername")

    expect(SyncStripeBusinessProfileUrlJob.jobs.size).to eq(1)
    expect(SyncStripeBusinessProfileUrlJob).to have_enqueued_sidekiq_job(123)
  end
end
