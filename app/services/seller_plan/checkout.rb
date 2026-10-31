# frozen_string_literal: true

module SellerPlan
  # Hosted Stripe Checkout on Gumroad's own account (not the seller's Connect account): here Gumroad
  # is the merchant charging the seller, so the platform key is the right one.
  class Checkout
    # Expected outcomes, so the controller can tell the seller what to do instead of showing a
    # generic failure. A price that has not been created in Stripe is an operational gap, not a bug.
    Error = Class.new(StandardError)
    AlreadyActive = Class.new(Error)
    PriceMissing = Class.new(Error)

    def initialize(offer:, success_url:, cancel_url:)
      @offer = offer
      @success_url = success_url
      @cancel_url = cancel_url
    end

    def url
      price_id = Experiment.price_id(@offer.arm)
      raise PriceMissing, "No Stripe price configured for the #{@offer.arm} arm" if price_id.blank?

      @offer.with_lock do
        raise AlreadyActive, "Seller plan is already active" if @offer.active?

        existing_checkout_destination || create_session(price_id)
      end
    end

    private
      def existing_checkout_destination
        return if @offer.stripe_checkout_session_id.blank?

        session = Stripe::Checkout::Session.retrieve(@offer.stripe_checkout_session_id)
        session.url if session.status == "open"
      rescue Stripe::InvalidRequestError
        nil
      end

      def create_session(price_id)
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

        attributes = { stripe_checkout_session_id: session.id }
        attributes[:status] = "checkout_started" if %w[offered canceled].include?(@offer.status)
        @offer.update!(attributes)
        session.url
      end

      def offer_metadata
        { "seller_plan_offer_id" => @offer.id.to_s, "user_id" => @offer.user_id.to_s }
      end
  end
end
