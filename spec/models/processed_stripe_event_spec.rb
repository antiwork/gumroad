# frozen_string_literal: true

require "spec_helper"

describe ProcessedStripeEvent do
  describe ".processed?" do
    it "is false for an unrecorded event and true after it is recorded" do
      expect(described_class.processed?("evt_123")).to be(false)

      described_class.record!("evt_123", event_type: "payment_intent.succeeded")

      expect(described_class.processed?("evt_123")).to be(true)
      expect(described_class.processed?("evt_other")).to be(false)
    end
  end

  describe ".record!" do
    it "persists the event id and type" do
      described_class.record!("evt_abc", event_type: "payment_intent.processing")

      record = described_class.find_by(event_id: "evt_abc")
      expect(record.event_type).to eq("payment_intent.processing")
    end

    it "is a no-op when the same event is recorded twice" do
      described_class.record!("evt_dup")

      expect do
        described_class.record!("evt_dup")
      end.not_to change { described_class.count }
    end

    it "swallows the unique-index violation that a raw create! would raise" do
      described_class.create!(event_id: "evt_raw")

      expect { described_class.create!(event_id: "evt_raw") }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { described_class.record!("evt_raw") }.not_to raise_error
    end
  end
end
