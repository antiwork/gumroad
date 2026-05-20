# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillRadarValueLists do
  let(:value_list) { double("ValueList", id: "rsl_123") }

  def block_platform!(type, value, by_user_id = nil, expires_in: nil)
    now = Time.current
    PlatformBlock.create_or_find_by!(object_type: type, object_value: value).tap do |record|
      record.update!(blocked_at: now, blocked_by: by_user_id, expires_at: expires_in.present? ? now + expires_in : nil)
    end
  end

  before do
    allow(Stripe::Radar::ValueList).to receive(:retrieve).and_return(value_list)
  end

  describe "#process" do
    it "pushes all active blocked emails and cards regardless of date" do
      travel_to 1.year.ago do
        block_platform!(BLOCKED_OBJECT_TYPES[:email], "old@example.com", nil)
        block_platform!(BLOCKED_OBJECT_TYPES[:charge_processor_fingerprint], "fpold", nil)
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

    it "does not push entries that are not in the table" do
      block_platform!(BLOCKED_OBJECT_TYPES[:email], "to-destroy@example.com", nil).destroy!

      expect(Stripe::Radar::ValueListItem).not_to receive(:create)

      described_class.process
    end

    it "processes entries in batches" do
      3.times { |i| block_platform!(BLOCKED_OBJECT_TYPES[:email], "buyer-#{i}@example.com", nil) }
      allow(Stripe::Radar::ValueListItem).to receive(:create)

      expect { described_class.process(batch_size: 2) }.to output(/Radar email backfill: 2 pushed.*Radar email backfill: 3 pushed/m).to_stdout
    end

    it "ignores duplicate item errors" do
      block_platform!(BLOCKED_OBJECT_TYPES[:email], "dup@example.com", nil)

      allow(Stripe::Radar::ValueListItem).to receive(:create)
        .and_raise(Stripe::InvalidRequestError.new("This value already exists", "value", code: "value_list_item_already_exists"))

      expect { described_class.process }.not_to raise_error
    end
  end
end
