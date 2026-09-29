# frozen_string_literal: true

require "spec_helper"

describe DeleteOldPingDeliveriesJob do
  it "deletes rows older than the retention window and keeps recent ones" do
    old = create(:ping_delivery, created_at: 91.days.ago)
    recent = create(:ping_delivery, created_at: 1.day.ago)

    described_class.new.perform

    expect(PingDelivery.pluck(:id)).to eq([recent.id])
    expect(PingDelivery.exists?(old.id)).to be(false)
  end

  it "does nothing when no rows are old enough" do
    create(:ping_delivery, created_at: 1.day.ago)

    expect(ReplicaLagWatcher).not_to receive(:watch)

    described_class.new.perform

    expect(PingDelivery.count).to eq(1)
  end
end
