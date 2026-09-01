# frozen_string_literal: true

require "spec_helper"

describe FinalizeBuyerPresentmentPurchaseJob do
  let(:purchase) do
    create(:purchase,
           purchase_state: "in_progress",
           stripe_transaction_id: "ch_presentment")
  end

  before do
    create(:purchase_presentment, purchase:, charge_presentment: nil)
  end

  it "finalizes a settled purchase" do
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: true)
    expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).with(purchase).and_return(sync_service)

    described_class.new.perform(purchase.id)

    expect(described_class.jobs.size).to eq(0)
  end

  it "retries with backoff while Stripe settlement data is missing" do
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: false)
    allow(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).and_return(sync_service)

    described_class.new.perform(purchase.id, 0)

    expect(described_class.jobs.size).to eq(1)
    expect(described_class.jobs.first["args"]).to eq([purchase.id, 1])
  end

  it "alerts instead of rescheduling once retries are exhausted" do
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: false)
    allow(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).and_return(sync_service)
    expect(ErrorNotifier).to receive(:notify).with(anything, context: hash_including(purchase_id: purchase.id))

    described_class.new.perform(purchase.id, described_class::RETRY_DELAYS.length)

    expect(described_class.jobs.size).to eq(0)
  end

  it "selects a PaymentIntent-only purchase with no Charge row" do
    purchase.update!(stripe_transaction_id: nil, processor_payment_intent_id: "pi_ignored_column", flow_of_funds: nil)
    purchase.create_processor_payment_intent!(intent_id: "pi_presentment")
    expect(purchase.reload.charge).to be_nil
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: true)
    expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).with(purchase).and_return(sync_service)

    described_class.new.perform(purchase.id)

    expect(described_class.jobs.size).to eq(0)
  end

  it "does not select an abandoned purchase with no PaymentIntent" do
    purchase.update!(stripe_transaction_id: nil, processor_payment_intent_id: "pi_ignored_column", flow_of_funds: nil)
    expect(purchase.reload.charge).to be_nil
    expect(Purchase::SyncStatusWithChargeProcessorService).not_to receive(:new)

    described_class.new.perform(purchase.id)

    expect(described_class.jobs.size).to eq(0)
  end

  it "no-ops for purchases without a presentment snapshot" do
    purchase.purchase_presentment.destroy!
    expect(Purchase::SyncStatusWithChargeProcessorService).not_to receive(:new)

    described_class.new.perform(purchase.id)

    expect(described_class.jobs.size).to eq(0)
  end
end
