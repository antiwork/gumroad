# frozen_string_literal: true

require "spec_helper"

describe DeleteOldProcessedStripeEventsJob do
  describe "#perform" do
    it "deletes rows older than the retention window and keeps recent ones" do
      ProcessedStripeEvent.create!(event_id: "evt_old", created_at: 2.months.ago)
      ProcessedStripeEvent.create!(event_id: "evt_recent", created_at: 1.day.ago)

      described_class.new.perform

      expect(ProcessedStripeEvent.pluck(:event_id)).to eq(["evt_recent"])
    end

    it "does not fail when there are no records" do
      expect(described_class.new.perform).to eq(nil)
    end

    it "short-circuits without touching the replica watcher when no rows are old enough" do
      ProcessedStripeEvent.create!(event_id: "evt_recent_only", created_at: 1.day.ago)

      expect(ReplicaLagWatcher).not_to receive(:watch)

      described_class.new.perform

      expect(ProcessedStripeEvent.exists?(event_id: "evt_recent_only")).to be(true)
    end
  end
end
