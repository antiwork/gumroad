# frozen_string_literal: true

require "spec_helper"

describe Mcp::DeleteExpiredEventSubscriptionsJob do
  it "deletes subscriptions whose lease has ended and keeps the same seller's live ones" do
    expired = create(:mcp_event_subscription, expires_at: 1.minute.ago)
    live = create(:mcp_event_subscription, user: expired.user, callback_url: "https://example.org/hooks/mcp", expires_at: 1.minute.from_now)

    described_class.new.perform

    expect(McpEventSubscription.all).to eq([live])
  end

  it "deletes in batches of sellers until no expired subscription is left" do
    stub_const("#{described_class}::SELLERS_PER_BATCH", 2)
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
