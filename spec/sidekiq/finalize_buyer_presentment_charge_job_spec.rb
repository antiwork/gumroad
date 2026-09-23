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

  context "with real purchase finalization" do
    let(:processor_charge) do
      BaseProcessorCharge.new.tap do |result|
        result.id = purchase.stripe_transaction_id
        result.status = "succeeded"
        result.charge_processor_id = StripeChargeProcessor.charge_processor_id
        result.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, charge.amount_cents)
      end
    end

    before do
      charge.order.purchases << purchase
      allow(ChargeProcessor).to receive(:get_or_search_charge).and_return(processor_charge)
      SendChargeReceiptJob.clear
      SendPurchaseReceiptJob.clear
    end

    it "enqueues exactly one receipt through sync after finalizing the purchase" do
      described_class.new.perform(charge.id)

      expect(purchase.reload).to be_successful
      expect(purchase.url_redirect).to be_present
      expect(SendPurchaseReceiptJob.jobs.size).to eq(0)
      expect(SendChargeReceiptJob.jobs.size).to eq(1)
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id).on("critical")
    end

    it "enqueues exactly one receipt on the critical queue when the PDF still needs stamping" do
      purchase.link.product_files << create(:readable_document, pdf_stamp_enabled: true)

      described_class.new.perform(charge.id)

      expect(purchase.reload).to be_successful
      expect(purchase.url_redirect).to be_present
      expect(SendChargeReceiptJob.jobs.size).to eq(1)
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id).on("critical")
    end

    it "lets ordinary sync schedule the receipt for a settlement-deferrable charge" do
      expect(Purchase::SyncStatusWithChargeProcessorService.new(purchase).perform).to be(true)

      expect(purchase.reload).to be_successful
      expect(SendChargeReceiptJob.jobs.size).to eq(1)
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id).on("critical")
    end

    it "propagates receipt enqueue errors and enqueues on retry after the purchase finalized" do
      enqueue_error = RedisClient::CannotConnectError.new("receipt Redis unavailable")
      allow(SendChargeReceiptJob).to receive(:client_push).and_raise(enqueue_error)

      expect { described_class.new.perform(charge.id) }.to raise_error(enqueue_error)

      expect(purchase.reload).to be_successful
      expect(purchase.url_redirect).to be_present
      expect(charge.reload).not_to be_receipt_sent
      expect(SendChargeReceiptJob.jobs.size).to eq(0)
      expect(SendChargeReceiptJob).to have_received(:client_push).once

      allow(SendChargeReceiptJob).to receive(:client_push).and_call_original
      described_class.new.perform(charge.id)

      expect(ChargeProcessor).to have_received(:get_or_search_charge).once
      expect(SendChargeReceiptJob.jobs.size).to eq(1)
      expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge.id).on("critical")
    end
  end

  it "finalizes settled purchases and sends the withheld charge receipt" do
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: true)
    expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).with(purchase, enqueue_charge_receipt: false).and_return(sync_service)

    described_class.new.perform(charge.id)

    expect(SendChargeReceiptJob.jobs.size).to eq(1)
    expect(SendChargeReceiptJob.jobs.first["args"]).to eq([charge.id])
  end

  it "polls in_progress purchases that have a PaymentIntent but no stripe_transaction_id" do
    purchase.update!(stripe_transaction_id: nil)
    charge.update!(stripe_payment_intent_id: nil, processor_transaction_id: nil)
    purchase.create_processor_payment_intent!(intent_id: "pi_presentment")
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: true)
    expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).with(purchase, enqueue_charge_receipt: false).and_return(sync_service)

    described_class.new.perform(charge.id)

    expect(SendChargeReceiptJob.jobs.size).to eq(1)
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

  it "no-ops for Gumroad-held charges without a presentment snapshot" do
    charge.charge_presentment.destroy!
    gumroad_held_merchant_account = create(:merchant_account, user: nil,
                                                              charge_processor_merchant_id: "acct_gumroad_held_no_presentment")
    charge.update!(merchant_account: gumroad_held_merchant_account)
    purchase.update!(merchant_account: gumroad_held_merchant_account)
    expect(Purchase::SyncStatusWithChargeProcessorService).not_to receive(:new)

    described_class.new.perform(charge.id)

    expect(SendChargeReceiptJob.jobs.size).to eq(0)
  end

  it "polls seller-held charges without a presentment snapshot" do
    charge.charge_presentment.destroy!
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: false)
    expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).with(purchase, enqueue_charge_receipt: false).and_return(sync_service)

    described_class.new.perform(charge.id)

    expect(described_class.jobs.size).to eq(1)
  end

  it "polls charges whose merchant account is missing" do
    charge.charge_presentment.destroy!
    charge.update!(merchant_account: nil)
    purchase.update_column(:merchant_account_id, nil)
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: false)
    expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new).with(purchase, enqueue_charge_receipt: false).and_return(sync_service)

    described_class.new.perform(charge.id)

    expect(described_class.jobs.size).to eq(1)
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
