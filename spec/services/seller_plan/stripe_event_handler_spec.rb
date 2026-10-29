# frozen_string_literal: true

require "spec_helper"

describe SellerPlan::StripeEventHandler do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:, draft: true) }
  let(:offer) { SellerPlanOffer.record_offer!(user:, link: product, arm: "ten", price_cents: 1000) }
  let(:metadata) { { "seller_plan_offer_id" => offer.id.to_s } }

  def event(type, object)
    { "type" => type, "data" => { "object" => object } }
  end

  it "activates the offer when checkout completes" do
    described_class.handle_stripe_event(
      event("checkout.session.completed", {
              "metadata" => metadata,
              "customer" => "cus_123",
              "subscription" => "sub_123"
            })
    )

    offer.reload
    expect(offer.status).to eq("active")
    expect(offer.stripe_customer_id).to eq("cus_123")
    expect(offer.stripe_subscription_id).to eq("sub_123")
    expect(offer.activated_at).to be_present
  end

  it "cancels the offer when the subscription is deleted" do
    offer.update!(status: "active", activated_at: Time.current)

    described_class.handle_stripe_event(
      event("customer.subscription.deleted", { "metadata" => metadata, "status" => "canceled" })
    )

    expect(offer.reload.status).to eq("canceled")
    expect(offer.canceled_at).to be_present
  end

  it "marks a failed payment past due without cancelling" do
    offer.update!(status: "active")

    described_class.handle_stripe_event(
      event("customer.subscription.updated", { "metadata" => metadata, "status" => "past_due" })
    )

    expect(offer.reload.status).to eq("past_due")
  end

  it "ignores events that do not carry an offer id" do
    expect do
      described_class.handle_stripe_event(
        event("checkout.session.completed", { "metadata" => {}, "customer" => "cus_other", "subscription" => "sub_other" })
      )
    end.not_to change { offer.reload.status }
  end
end
