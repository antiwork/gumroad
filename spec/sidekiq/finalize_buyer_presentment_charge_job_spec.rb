# frozen_string_literal: true

require "spec_helper"

describe FinalizeBuyerPresentmentChargeJob do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:charge) { create(:charge, order: create(:order), seller:, merchant_account:) }
  let(:purchase) do
    create(:purchase,
           link: create(:product, user: seller),
           seller:,
           merchant_account:,
           purchase_state: "in_progress",
           stripe_transaction_id: "ch_presentment")
  end

  before do
    create(:charge_presentment, charge:)
    charge.purchases << purchase
  end

  it "finalizes settled purchases and sends the withheld charge receipt" do
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: true)
    expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).with(purchase).and_return(sync_service)

    described_class.new.perform(charge.id)

    expect(SendChargeReceiptJob.jobs.size).to eq(1)
    expect(SendChargeReceiptJob.jobs.first["args"]).to eq([charge.id])
  end

  it "retries with backoff while Stripe settlement data is missing" do
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: false)
    allow(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).and_return(sync_service)

    described_class.new.perform(charge.id, 0)

    expect(SendChargeReceiptJob.jobs.size).to eq(0)
    expect(described_class.jobs.size).to eq(1)
    expect(described_class.jobs.first["args"]).to eq([charge.id, 1])
  end

  it "alerts instead of rescheduling once retries are exhausted" do
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: false)
    allow(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).and_return(sync_service)
    expect(ErrorNotifier).to receive(:notify).with(anything, context: hash_including(charge_id: charge.id))

    described_class.new.perform(charge.id, described_class::RETRY_DELAYS.length)

    expect(described_class.jobs.size).to eq(0)
  end

  it "no-ops for charges without a presentment snapshot" do
    charge.charge_presentment.destroy!
    expect(Purchase::SyncStatusWithChargeProcessorService).not_to receive(:new)

    described_class.new.perform(charge.id)

    expect(SendChargeReceiptJob.jobs.size).to eq(0)
  end

  it "re-enqueues the receipt when purchases finalized but the receipt was never sent" do
    # Simulates a Sidekiq retry after the original SendChargeReceiptJob enqueue failed
    # (e.g. transient Redis error): the purchase is already successful, so pending_purchases
    # is empty, but charge.receipt_sent? is still false.
    purchase.update!(purchase_state: "successful", succeeded_at: Time.current)
    expect(Purchase::SyncStatusWithChargeProcessorService).not_to receive(:new)

    described_class.new.perform(charge.id)

    expect(SendChargeReceiptJob.jobs.size).to eq(1)
    expect(SendChargeReceiptJob.jobs.first["args"]).to eq([charge.id])
  end

  it "does not re-enqueue the receipt once it has already been sent" do
    purchase.update!(purchase_state: "successful", succeeded_at: Time.current)
    charge.update!(receipt_sent: true)
    expect(Purchase::SyncStatusWithChargeProcessorService).not_to receive(:new)

    described_class.new.perform(charge.id)

    expect(SendChargeReceiptJob.jobs.size).to eq(0)
  end
end
