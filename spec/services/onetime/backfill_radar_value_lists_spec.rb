# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillRadarValueLists do
  let(:value_list) { double("ValueList", id: "rsl_123") }

  before do
    allow(Stripe::Radar::ValueList).to receive(:list).and_return(double(data: [value_list]))
  end

  describe "#process" do
    it "pushes all active blocked emails and cards regardless of date" do
      travel_to 1.year.ago do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "old@example.com")
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:charge_processor_fingerprint], object_value: "fpold")
      end

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(
        value_list: "rsl_123",
        value: "old@example.com"
      )
      expect(Stripe::Radar::ValueListItem).to receive(:create).with(
        value_list: "rsl_123",
        value: "fpold"
      )

      described_class.process
    end

    it "skips unblocked entries" do
      blocked = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "unblocked@example.com")
      blocked.unblock!

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      described_class.process
    end

    it "processes entries in batches" do
      3.times { |i| PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "buyer-#{i}@example.com") }
      allow(Stripe::Radar::ValueListItem).to receive(:create)

      expect { described_class.process(batch_size: 2) }.to output(/Radar email backfill: 2 pushed.*Radar email backfill: 3 pushed/m).to_stdout
    end

    it "ignores duplicate item errors" do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "dup@example.com")

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This value already exists", "value", code: "value_list_item_already_exists"))

      expect { described_class.process }.not_to raise_error
    end

    it "scopes by since:" do
      travel_to 2.months.ago do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "tooold@example.com")
      end
      travel_to 2.weeks.ago do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "recent@example.com")
      end

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(value_list: "rsl_123", value: "recent@example.com")
      expect(Stripe::Radar::ValueListItem).not_to receive(:create).with(value_list: "rsl_123", value: "tooold@example.com")

      described_class.process(since: 1.month.ago)
    end

    it "scopes by before:" do
      travel_to 2.months.ago do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "old@example.com")
      end
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "fresh@example.com")

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(value_list: "rsl_123", value: "old@example.com")
      expect(Stripe::Radar::ValueListItem).not_to receive(:create).with(value_list: "rsl_123", value: "fresh@example.com")

      described_class.process(before: 1.month.ago)
    end

    it "scopes by since: and before: together" do
      travel_to 2.months.ago do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "tooold@example.com")
      end
      travel_to 2.weeks.ago do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "inrange@example.com")
      end
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "toonew@example.com")

      expect(Stripe::Radar::ValueListItem).to receive(:create).with(value_list: "rsl_123", value: "inrange@example.com")
      expect(Stripe::Radar::ValueListItem).not_to receive(:create).with(value_list: "rsl_123", value: "tooold@example.com")
      expect(Stripe::Radar::ValueListItem).not_to receive(:create).with(value_list: "rsl_123", value: "toonew@example.com")

      described_class.process(since: 1.month.ago, before: 1.day.ago)
    end
  end
end
