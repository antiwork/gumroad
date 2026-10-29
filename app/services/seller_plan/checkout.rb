# frozen_string_literal: true

module SellerPlan
  # Hosted Stripe Checkout on Gumroad's own account (not the seller's Connect account): here Gumroad
  # is the merchant charging the seller, so the platform key is the right one.
  class Checkout
    def initialize(offer:, success_url:, cancel_url:)
      @offer = offer
      @success_url = success_url
      @cancel_url = cancel_url
    end

    def url
      price_id = Experiment.price_id(@offer.arm)
      raise "No Stripe price configured for the #{@offer.arm} arm" if price_id.blank?

      session = Stripe::Checkout::Session.create(
        mode: "subscription",
        line_items: [{ price: price_id, quantity: 1 }],
        customer_email: @offer.user.email,
        client_reference_id: @offer.id.to_s,
        metadata: offer_metadata,
        subscription_data: { metadata: offer_metadata },
        success_url: @success_url,
        cancel_url: @cancel_url,
        allow_promotion_codes: false
      )

      @offer.update!(stripe_checkout_session_id: session.id, status: "checkout_started")
      session.url
    end

    private
      def offer_metadata
        { "seller_plan_offer_id" => @offer.id.to_s, "user_id" => @offer.user_id.to_s }
      end
  end
end
