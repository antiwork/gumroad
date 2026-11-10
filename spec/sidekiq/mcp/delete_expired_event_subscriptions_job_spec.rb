# frozen_string_literal: true

require "spec_helper"

describe Mcp::DeleteExpiredEventSubscriptionsJob do
  it "deletes subscriptions whose lease has ended and keeps live ones" do
    create(:mcp_event_subscription, expires_at: 1.minute.ago)
    live = create(:mcp_event_subscription, expires_at: 1.minute.from_now)

    described_class.new.perform

    expect(McpEventSubscription.all).to eq([live])
  end

  it "deletes in batches until no expired subscription is left" do
    stub_const("#{described_class}::DELETION_BATCH_SIZE", 2)
    3.times { create(:mcp_event_subscription, expires_at: 1.minute.ago) }

    described_class.new.perform

    expect(McpEventSubscription.count).to eq(0)
  end

  it "does nothing when no lease has ended" do
    create(:mcp_event_subscription, expires_at: 1.minute.from_now)
    expect(ReplicaLagWatcher).not_to receive(:watch)

    described_class.new.perform

    expect(McpEventSubscription.count).to eq(1)
  end
end
