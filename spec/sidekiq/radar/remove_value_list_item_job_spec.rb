# frozen_string_literal: true

require "spec_helper"

describe Radar::RemoveValueListItemJob do
  let(:value_list) { double("ValueList", id: "rsl_123") }

  before do
    allow(Stripe::Radar::ValueList).to receive(:list).and_return(double(data: [value_list]))
  end

  it "runs in the critical queue: until it lands the buyer is still hard-blocked at checkout" do
    expect(described_class.sidekiq_options["queue"]).to eq("critical")
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
