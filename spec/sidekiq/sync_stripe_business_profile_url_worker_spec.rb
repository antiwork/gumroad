# frozen_string_literal: true

describe SyncStripeBusinessProfileUrlWorker do
  it "delegates to SyncStripeBusinessProfileUrlJob" do
    job = instance_double(SyncStripeBusinessProfileUrlJob)
    allow(SyncStripeBusinessProfileUrlJob).to receive(:new).and_return(job)
    expect(job).to receive(:perform).with(1, "old")

    described_class.new.perform(1, "old")
  end
end
