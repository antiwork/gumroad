# frozen_string_literal: true

require "spec_helper"

describe UnstickStuckInProgressPurchasesJob do
  it "runs the service live so the scheduled pass actually repairs rows" do
    expect(Purchase::UnstickStuckInProgressService).to receive(:process).with(dry_run: false, ids: nil)

    described_class.new.perform
  end

  it "passes an explicit id list through for a manual re-run" do
    expect(Purchase::UnstickStuckInProgressService).to receive(:process).with(dry_run: false, ids: [1, 2])

    described_class.new.perform([1, 2])
  end
end
