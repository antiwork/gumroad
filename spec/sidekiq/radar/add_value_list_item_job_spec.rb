# frozen_string_literal: true

require "spec_helper"

describe Radar::AddValueListItemJob do
  let(:value_list) { double("ValueList", id: "rsl_123") }

  before do
    allow(Radar::ValueListSyncService).to receive(:enabled?).and_return(true)
    allow(Stripe::Radar::ValueList).to receive(:list).and_return(double(data: [value_list]))
    allow(Stripe::Radar::ValueListItem).to receive(:list).and_return(double(data: []))
  end

  it "runs in the default queue" do
    expect(described_class.sidekiq_options["queue"]).to eq("default")
  end

  it "deduplicates concurrent adds of the same row" do
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  it "pushes the newly blocked email to the Radar list" do
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "blocked-now@example.com")

    expect(Stripe::Radar::ValueListItem).to receive(:create).with(value_list: "rsl_123", value: "blocked-now@example.com")

    described_class.new.perform(block.id)
  end

  it "does nothing when the block row no longer exists" do
    expect(Stripe::Radar::ValueListItem).not_to receive(:create)

    described_class.new.perform(0)
  end
end
