# frozen_string_literal: true

require "spec_helper"

describe "Purchase processor settlement predicates" do
  def pi_only_purchase
    purchase = create(:purchase,
                      purchase_state: "in_progress",
                      stripe_transaction_id: nil,
                      processor_payment_intent_id: "pi_ignored_column",
                      charge_processor_id: StripeChargeProcessor.charge_processor_id,
                      flow_of_funds: nil,
                      succeeded_at: nil)
    create(:purchase_presentment, purchase:, charge_presentment: nil)
    purchase.create_processor_payment_intent!(intent_id: "pi_presentment")
    purchase.reload
  end

  it "treats a purchase PaymentIntent as charged when no Charge row exists" do
    purchase = pi_only_purchase

    expect(purchase.charge).to be_nil
    expect(purchase.read_attribute(:processor_payment_intent_id)).to eq("pi_ignored_column")
    expect(purchase.processor_payment_intent_id).to eq("pi_presentment")
    expect(purchase.charged_at_processor?).to eq(true)
    expect(purchase.pending_processor_settlement?).to eq(true)
  end

  it "does not treat an abandoned purchase with no PaymentIntent as charged" do
    purchase = create(:purchase,
                      purchase_state: "in_progress",
                      stripe_transaction_id: nil,
                      processor_payment_intent_id: "pi_ignored_column",
                      charge_processor_id: StripeChargeProcessor.charge_processor_id,
                      flow_of_funds: nil,
                      succeeded_at: nil)
    create(:purchase_presentment, purchase:, charge_presentment: nil)

    expect(purchase.charge).to be_nil
    expect(purchase.processor_payment_intent).to be_nil
    expect(purchase.charged_at_processor?).to eq(false)
    expect(purchase.pending_processor_settlement?).to eq(false)
  end
end
