# frozen_string_literal: true

require "spec_helper"

describe Purchase::UnstickStuckInProgressService do
  let(:product) { create(:product) }

  # These specs are about this service's own decisions (which rows it selects, whether it writes,
  # what it reports). The processor round trip belongs to SyncStatusWithChargeProcessorService and
  # is stubbed here so no example depends on a recorded charge.
  def stuck_purchase(created_at:)
    create(:purchase_in_progress, link: product, created_at:)
  end

  # Stands in for the sync service: reports `result` from #perform, `outcome` from #charge_outcome,
  # and runs `block` against the purchase it was handed so an example can simulate the write.
  def stub_sync(result, outcome: :succeeded, &block)
    allow(Purchase::SyncStatusWithChargeProcessorService).to receive(:new) do |purchase, **|
      block&.call(purchase)
      instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: result, charge_outcome: outcome)
    end
  end

  describe "dry run" do
    it "defaults to dry run and writes nothing" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      expect(Purchase::SyncStatusWithChargeProcessorService).to_not receive(:new)

      expect { described_class.process }.to_not change { purchase.reload.purchase_state }
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
      expect(Purchase::SyncStatusWithChargeProcessorService).to_not receive(:new)

      expect { described_class.new.process }.to_not change { purchase.reload.purchase_state }
    end
  end

  describe "live run" do
    it "recovers a purchase older than SyncStuckPurchasesJob's three-day window" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      stub_sync(true) { |p| p.update_columns(purchase_state: "successful") }

      result = described_class.process(dry_run: false)

      expect(purchase.reload).to be_successful
      expect(result[:recovered]).to eq(1)
    end

    it "leaves a purchase still inside SyncStuckPurchasesJob's own window alone" do
      purchase = stuck_purchase(created_at: 2.days.ago)
      expect(Purchase::SyncStatusWithChargeProcessorService).to_not receive(:new)

      result = described_class.process(dry_run: false)

      expect(purchase.reload).to be_in_progress
      expect(result[:scanned]).to eq(0)
    end

    it "ignores a purchase older than the maximum age" do
      stuck_purchase(created_at: 100.days.ago)

      expect(described_class.process(dry_run: false)[:scanned]).to eq(0)
    end

    it "restricts the run to an explicit id list" do
      targeted = stuck_purchase(created_at: 10.days.ago)
      untouched = stuck_purchase(created_at: 11.days.ago)
      synced = []
      stub_sync(true) { |p| synced << p.id }

      described_class.process(dry_run: false, ids: [targeted.id])

      expect(synced).to eq([targeted.id])
      expect(untouched.reload).to be_in_progress
    end

    it "asks the sync path not to fail the purchase" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      allow(ErrorNotifier).to receive(:notify)

      expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new)
        .with(purchase_with_id(purchase.id))
        .and_return(instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: false, charge_outcome: :succeeded))

      described_class.process(dry_run: false)
    end

    it "skips a purchase that cannot be force updated" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      allow_any_instance_of(Purchase).to receive(:can_force_update?).and_return(false)
      expect(Purchase::SyncStatusWithChargeProcessorService).to_not receive(:new)

      result = described_class.process(dry_run: false)

      expect(purchase.reload).to be_in_progress
      expect(result[:skipped]).to eq(1)
      expect(result[:recovered]).to eq(0)
    end

    it "counts a row as recovered when sync reports false but the row did reach successful" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      stub_sync(false) { |p| p.update_columns(purchase_state: "successful") }

      result = described_class.process(dry_run: false)

      expect(purchase.reload).to be_successful
      expect(result[:recovered]).to eq(1)
      expect(result[:unrecoverable]).to eq(0)
    end

    it "alerts with the ids it could not heal" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      stub_sync(false)

      expect(ErrorNotifier).to receive(:notify).with(
        "Purchases stuck in_progress with a succeeded charge could not be recovered",
        context: hash_including(purchase_ids: [purchase.id])
      )

      result = described_class.process(dry_run: false)

      expect(result[:unrecoverable]).to eq(1)
      expect(result[:unrecoverable_ids]).to eq([purchase.id])
    end

    %i[missing refunded disputed pending unsuccessful].each do |outcome|
      it "keeps a #{outcome} charge out of the succeeded-charge alert" do
        purchase = stuck_purchase(created_at: 10.days.ago)
        stub_sync(false, outcome:)
        alerts = []
        allow(ErrorNotifier).to receive(:notify) { |title, **rest| alerts << [title, rest] }

        result = described_class.process(dry_run: false)

        expect(result[:unrecoverable]).to eq(0)
        expect(result[:unrecoverable_ids]).to be_empty
        expect(result[:other_charge_state]).to eq(1)
        expect(result[:other_ids_by_outcome]).to eq(outcome => [purchase.id])
        expect(alerts.map(&:first)).to eq(["Purchases stuck in_progress without a succeeded charge"])
        expect(alerts.first.last[:context][:purchase_ids_by_charge_state]).to eq(outcome => [purchase.id])
      end
    end

    it "reports a succeeded-charge row and a non-succeeded one in separate alerts" do
      stuck = stuck_purchase(created_at: 10.days.ago)
      refunded = stuck_purchase(created_at: 11.days.ago)
      allow(Purchase::SyncStatusWithChargeProcessorService).to receive(:new) do |purchase, **|
        outcome = purchase.id == stuck.id ? :succeeded : :refunded
        instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: false, charge_outcome: outcome)
      end
      titles = []
      allow(ErrorNotifier).to receive(:notify) { |title, **| titles << title }

      result = described_class.process(dry_run: false)

      expect(result[:unrecoverable_ids]).to eq([stuck.id])
      expect(result[:other_ids_by_outcome]).to eq(refunded: [refunded.id])
      expect(titles).to contain_exactly(
        "Purchases stuck in_progress with a succeeded charge could not be recovered",
        "Purchases stuck in_progress without a succeeded charge"
      )
    end

    it "stays silent when asked not to notify" do
      stuck_purchase(created_at: 10.days.ago)
      stub_sync(false)

      expect(ErrorNotifier).to_not receive(:notify)

      expect(described_class.process(dry_run: false, notify: false)[:unrecoverable]).to eq(1)
    end

    it "keeps going and reports the error when one row raises" do
      first = stuck_purchase(created_at: 11.days.ago)
      second = stuck_purchase(created_at: 10.days.ago)
      seen = []
      allow(Purchase::SyncStatusWithChargeProcessorService).to receive(:new) do |purchase, **|
        seen << purchase.id
        raise StandardError, "boom" if purchase.id == first.id

        purchase.update_columns(purchase_state: "successful")
        instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: true, charge_outcome: :succeeded)
      end
      allow(ErrorNotifier).to receive(:notify)

      result = described_class.process(dry_run: false)

      expect(seen).to include(first.id, second.id)
      expect(result[:failed]).to eq(1)
      expect(result[:recovered]).to eq(1)
      expect(second.reload).to be_successful
    end

    it "leaves a row a concurrent sync resolved between selection and the re-read alone" do
      purchase = stuck_purchase(created_at: 10.days.ago)
      # The scan selects the row while it is still in_progress; a webhook-driven sync then wins the
      # race, so the re-read must find it resolved and skip the processor round trip.
      allow_any_instance_of(Purchase).to receive(:reload).and_wrap_original do |orig, *args|
        purchase.update_columns(purchase_state: "successful")
        orig.call(*args)
      end

      expect(Purchase::SyncStatusWithChargeProcessorService).to_not receive(:new)

      result = described_class.process(dry_run: false)

      expect(result[:already_resolved]).to eq(1)
      expect(result[:recovered]).to eq(0)
      expect(result[:unrecoverable]).to eq(0)
    end

    it "counts a row the sync path itself found already resolved as resolved, not unrecoverable" do
      stuck_purchase(created_at: 10.days.ago)
      # charge_outcome stays nil when the sync returns before consulting the processor, which is
      # what happens when the row is no longer in_progress by the time it holds the lock.
      stub_sync(false, outcome: nil)

      result = described_class.process(dry_run: false)

      expect(result[:already_resolved]).to eq(1)
      expect(result[:unrecoverable]).to eq(0)
    end
  end

  # Matches whichever Purchase instance the service loaded for this row.
  def purchase_with_id(id)
    satisfy { |arg| arg.is_a?(Purchase) && arg.id == id }
  end
end
