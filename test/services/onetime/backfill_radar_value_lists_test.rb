# frozen_string_literal: true

require "test_helper"

class OnetimeBackfillRadarValueListsTest < ActiveSupport::TestCase
  self.described_class = Onetime::BackfillRadarValueLists



  context_ Onetime::BackfillRadarValueLists do
    let(:value_list) { double("ValueList", id: "rsl_123") }

    before do
      allow(Stripe::Radar::ValueList).to receive(:retrieve).and_return(value_list)
    end

  context_ "#process" do
  test "pushes all active blocked emails and cards regardless of date" do
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

  test "skips unblocked entries" do
        blocked = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "unblocked@example.com")
        blocked.unblock!

        expect(Stripe::Radar::ValueListItem).not_to receive(:create)

        described_class.process
      end

  test "processes entries in batches" do
        3.times { |i| PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "buyer-#{i}@example.com") }
        allow(Stripe::Radar::ValueListItem).to receive(:create)

        expect { described_class.process(batch_size: 2) }.to output(/Radar email backfill: 2 pushed.*Radar email backfill: 3 pushed/m).to_stdout
      end

  test "ignores duplicate item errors" do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "dup@example.com")

        allow(Stripe::Radar::ValueListItem).to receive(:create)
          .and_raise(Stripe::InvalidRequestError.new("This value already exists", "value", code: "value_list_item_already_exists"))

        expect { described_class.process }.not_to raise_error
      end
    end
  end
end
