# frozen_string_literal: true

require "spec_helper"

describe Onetime::DeleteEventsWithEmail do
  describe ".process" do
    it "deletes events that have an email and keeps events without one" do
      with_email = create(:event, email: "buyer@example.com")
      without_email = create(:event, email: nil)

      described_class.process

      expect(Event.exists?(with_email.id)).to be(false)
      expect(Event.exists?(without_email.id)).to be(true)
    end

    it "deletes across multiple batches and returns the total number deleted" do
      create_list(:event, 3, email: "buyer@example.com")
      create(:event, email: nil)

      expect(described_class.process(batch_size: 1)).to eq(3)
      expect(Event.where.not(email: nil).count).to eq(0)
    end

    it "pauses for replica lag, allowing up to 10 seconds of delay, between batches" do
      create(:event, email: "buyer@example.com")

      expect(ReplicaLagWatcher).to receive(:watch).with(max_lag_allowed: 10).at_least(:once)

      described_class.process
    end
  end
end
