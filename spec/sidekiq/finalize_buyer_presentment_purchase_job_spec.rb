# frozen_string_literal: true

require "spec_helper"

describe FinalizeBuyerPresentmentPurchaseJob do
  let(:purchase) do
    create(:purchase,
           purchase_state: "in_progress",
           charge_processor_id: StripeChargeProcessor.charge_processor_id,
           stripe_transaction_id: "ch_presentment")
  end

  before do
    create(:purchase_presentment, purchase:, charge_presentment: nil)
  end

  def stub_processor_charge(status:, flow_of_funds: nil)
    charge = BaseProcessorCharge.new
    charge.id = purchase.stripe_transaction_id
    charge.status = status
    charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
    charge.flow_of_funds = flow_of_funds
    allow(ChargeProcessor).to receive(:get_or_search_charge).and_return(charge)
    charge
  end

  it "finalizes a settled purchase" do
    sync_service = instance_double(Purchase::SyncStatusWithChargeProcessorService, perform: true)
    expect(Purchase::SyncStatusWithChargeProcessorService).to receive(:new)
      .with(purchase, mark_as_failed: false).and_return(sync_service)

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

  it "does not fail the purchase on intermediate attempts" do
    stub_processor_charge(status: "failed")

    described_class.new.perform(purchase.id, 0)

    expect(purchase.reload).to be_in_progress
    expect(described_class.jobs.size).to eq(1)
  end

  it "fails the purchase when the charge is still not successful after the last attempt" do
    stub_processor_charge(status: "failed")
    expect(ErrorNotifier).not_to receive(:notify)

    described_class.new.perform(purchase.id, described_class::RETRY_DELAYS.length)

    expect(purchase.reload).to be_failed
    expect(described_class.jobs.size).to eq(0)
  end

  it "keeps a succeeded charge in progress when settlement data never arrives, and alerts" do
    stub_processor_charge(status: "succeeded", flow_of_funds: nil)
    expect(ErrorNotifier).to receive(:notify).with(anything, context: hash_including(purchase_id: purchase.id))

    described_class.new.perform(purchase.id, described_class::RETRY_DELAYS.length)

    expect(purchase.reload).to be_in_progress
    expect(described_class.jobs.size).to eq(0)
  end

  it "no-ops for purchases without a presentment snapshot" do
    purchase.purchase_presentment.destroy!
    expect(Purchase::SyncStatusWithChargeProcessorService).not_to receive(:new)

    described_class.new.perform(purchase.id)

    expect(described_class.jobs.size).to eq(0)
  end
end
