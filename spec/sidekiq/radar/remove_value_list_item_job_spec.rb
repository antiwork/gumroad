# frozen_string_literal: true

require "spec_helper"

describe Radar::RemoveValueListItemJob do
  let(:value_list) { double("ValueList", id: "rsl_123") }

  before do
    allow(Radar::ValueListSyncService).to receive(:enabled?).and_return(true)
    allow(Stripe::Radar::ValueList).to receive(:list).and_return(double(data: [value_list]))
  end

  it "runs in the default queue" do
    expect(described_class.sidekiq_options["queue"]).to eq("default")
  end

  it "deduplicates concurrent removals of the same row" do
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  it "removes the unblocked email from the Radar list" do
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "cleared@example.com")
    block.update_columns(blocked_at: nil, expires_at: nil)

    item = double("ValueListItem", id: "rsli_456")
    allow(Stripe::Radar::ValueListItem).to receive(:list)
      .with(value_list: "rsl_123", value: "cleared@example.com")
      .and_return(double(data: [item]))

    expect(Stripe::Radar::ValueListItem).to receive(:delete).with("rsli_456")

    described_class.new.perform(block.id)
  end

  it "does nothing when the block row no longer exists" do
    expect(Stripe::Radar::ValueListItem).not_to receive(:delete)

    described_class.new.perform(0)
  end
end
