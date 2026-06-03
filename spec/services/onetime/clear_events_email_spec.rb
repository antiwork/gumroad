# frozen_string_literal: true

require "spec_helper"

describe Onetime::ClearEventsEmail do
  describe ".process" do
    it "nulls the email on events that have one and keeps the rows" do
      with_email = create(:event, email: "buyer@example.com")
      without_email = create(:event, email: nil)

      described_class.process

      expect(Event.exists?(with_email.id)).to be(true)
      expect(with_email.reload.email).to be_nil
      expect(Event.exists?(without_email.id)).to be(true)
    end

    it "clears across multiple batches and returns the total number cleared" do
      cleared = create_list(:event, 3, email: "buyer@example.com")
      create(:event, email: nil)

      expect(described_class.process(batch_size: 1)).to eq(3)
      expect(Event.where.not(email: nil).count).to eq(0)
      cleared.each { expect(_1.reload.email).to be_nil }
    end

    it "pauses for replica lag, allowing up to 10 seconds of delay, between batches" do
      create(:event, email: "buyer@example.com")

      expect(ReplicaLagWatcher).to receive(:watch).with(max_lag_allowed: 10).at_least(:once)

      described_class.process
    end
  end
end
