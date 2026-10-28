# frozen_string_literal: true

require "spec_helper"

describe RetryPendingMandateChargeJob do
  let(:order) { create(:order) }
  let(:purchase) { create(:purchase_in_progress, order:, stripe_transaction_id: nil) }
  let(:service) { instance_double(Order::ConfirmService, charge_pending_setup_groups!: {}, mandate_pending_purchases: [purchase]) }

  before do
    order.purchases << purchase
    allow(Order::ConfirmService).to receive(:new).with(order:, params: { buyer_currency_quote: nil }).and_return(service)
  end

  it "does nothing for a missing order" do
    expect(Order::ConfirmService).not_to receive(:new)
    described_class.new.perform(0)
  end

  it "reschedules while a group is still held inside the wait window" do
    described_class.new.perform(order.id)

    expect(described_class.jobs.size).to eq(1)
    expect(purchase.reload.purchase_state).to eq("in_progress")
  end

  it "fails the held group with the pending-mandate error once the wait is over" do
    purchase.update!(created_at: (described_class::MAX_WAIT + 1.minute).ago)

    described_class.new.perform(order.id)

    expect(described_class.jobs).to be_empty
    purchase.reload
    expect(purchase.purchase_state).to eq("failed")
    expect(purchase.error_code).to eq(PurchaseErrorCode::INDIA_CARD_MANDATE_PENDING)
  end

  it "does not fail a held group that was charged in the meantime" do
    purchase.update!(created_at: (described_class::MAX_WAIT + 1.minute).ago)
    purchase.create_processor_payment_intent!(intent_id: "pi_paid")

    described_class.new.perform(order.id)

    expect(purchase.reload.purchase_state).to eq("in_progress")
    expect(purchase.error_code).to be_nil
  end

  it "finishes a declined group even while another group is still held" do
    declined = create(:purchase_in_progress, order:, stripe_transaction_id: nil)
    order.purchases << declined
    declined.errors.add(:base, "declined")
    allow(order).to receive(:purchases).and_return(order.purchases.to_a)
    allow(Order).to receive(:find_by).with(id: order.id).and_return(order)
    confirm = instance_double(Purchase::ConfirmService, perform: "declined")
    expect(Purchase::ConfirmService).to receive(:new).with(purchase: declined, params: { buyer_currency_quote: nil }).and_return(confirm)

    described_class.new.perform(order.id)

    expect(described_class.jobs.size).to eq(1)
  end

  it "does nothing more when the groups were charged" do
    allow(service).to receive(:mandate_pending_purchases).and_return([])

    described_class.new.perform(order.id)

    expect(described_class.jobs).to be_empty
  end
end
