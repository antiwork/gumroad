# frozen_string_literal: true

require "spec_helper"

describe Purchase::UnstickStuckInProgressService, :vcr do
  let(:product) { create(:product) }

  def stuck_purchase(created_at:)
    travel_to(created_at) do
      purchase = create(:purchase, link: product, purchase_state: "in_progress", chargeable: create(:chargeable))
      purchase.process!
      purchase
    end
  end

  describe "dry run" do
    it "defaults to dry run and writes nothing" do
      purchase = stuck_purchase(created_at: 10.days.ago)

      expect { described_class.process }.to_not change { purchase.reload.purchase_state }
      expect(purchase.reload).to be_in_progress
    end

    it "reports the reviewed worklist without alerting" do
      purchase = stuck_purchase(created_at: 10.days.ago)

      expect(ErrorNotifier).to_not receive(:notify)

      result = described_class.process

      expect(result[:dry_run]).to eq(true)
      expect(result[:eligible_ids]).to include(purchase.id)
      expect(result[:recovered]).to eq(0)
    end

    it "does not write when called on the instance either" do
      purchase = stuck_purchase(created_at: 10.days.ago)

      expect { described_class.new.process }.to_not change { purchase.reload.purchase_state }
    end
  end

  describe "live run" do
    it "recovers a purchase older than SyncStuckPurchasesJob's three-day window" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      expect(purchase).to be_in_progress

      result = described_class.process(dry_run: false)

      expect(purchase.reload).to be_successful
      expect(result[:recovered]).to eq(1)
    end

    it "leaves a purchase younger than the minimum age alone" do
      purchase = stuck_purchase(created_at: 2.hours.ago)

      result = described_class.process(dry_run: false)

      expect(purchase.reload).to be_in_progress
      expect(result[:scanned]).to eq(0)
    end

    it "restricts the run to an explicit id list" do
      targeted = stuck_purchase(created_at: 10.days.ago)
      untouched = stuck_purchase(created_at: 11.days.ago)

      described_class.process(dry_run: false, ids: [targeted.id])

      expect(targeted.reload).to be_successful
      expect(untouched.reload).to be_in_progress
    end

    it "never marks a purchase failed, since the charge succeeded at the processor" do
      purchase = stuck_purchase(created_at: 10.days.ago)

      expect_any_instance_of(Purchase).to_not receive(:mark_failed!)

      described_class.process(dry_run: false)

      expect(purchase.reload).to_not be_failed
    end

    it "skips a purchase that cannot be force updated" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      allow_any_instance_of(Purchase).to receive(:can_force_update?).and_return(false)

      result = described_class.process(dry_run: false)

      expect(purchase.reload).to be_in_progress
      expect(result[:skipped]).to eq(1)
      expect(result[:recovered]).to eq(0)
    end

    it "alerts with the ids it could not heal" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      allow_any_instance_of(Purchase).to receive(:sync_status_with_charge_processor).and_return(false)

      expect(ErrorNotifier).to receive(:notify).with(
        "Purchases stuck in_progress with a succeeded charge could not be recovered",
        context: hash_including(purchase_ids: [purchase.id])
      )

      result = described_class.process(dry_run: false)

      expect(result[:unrecoverable]).to eq(1)
    end

    it "keeps going and reports the error when one row raises" do
      stuck_purchase(created_at: 10.days.ago)
      allow_any_instance_of(Purchase).to receive(:sync_status_with_charge_processor).and_raise(StandardError, "boom")
      allow(ErrorNotifier).to receive(:notify)

      result = described_class.process(dry_run: false)

      expect(result[:failed]).to eq(1)
    end
  end
end
