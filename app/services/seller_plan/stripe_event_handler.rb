# frozen_string_literal: true

module SellerPlan
  # Platform-account subscription events for the paid-publish experiment. Every event we care about
  # carries the offer id in metadata, so anything else on the endpoint (and any other Gumroad
  # integration on the same account) falls through untouched.
  class StripeEventHandler
    HANDLED_TYPES = %w[checkout.session.completed customer.subscription.].freeze

    def self.handles?(type)
      HANDLED_TYPES.any? { |handled| type.to_s.start_with?(handled) }
    end

    def self.handle_stripe_event(event)
      case event["type"]
      when "checkout.session.completed"
        activate_from_checkout(event["data"]["object"])
      when /\Acustomer\.subscription\./
        sync_subscription(event["data"]["object"])
      end
    end

    def self.activate_from_checkout(session)
      offer = offer_from(session["metadata"])
      return if offer.nil?

      if offer.active? && offer.stripe_subscription_id.present? && offer.stripe_subscription_id != session["subscription"]
        ErrorNotifier.notify("Seller plan offer #{offer.id} completed a second checkout (#{session["subscription"]})")
        return
      end

      offer.update!(
        status: "active",
        stripe_customer_id: session["customer"],
        stripe_subscription_id: session["subscription"],
        activated_at: Time.current,
        canceled_at: nil
      )
    end

    def self.sync_subscription(subscription)
      offer = offer_from(subscription["metadata"])
      return if offer.nil?
      return if offer.stripe_subscription_id.present? && offer.stripe_subscription_id != subscription["id"]

      offer.update!(stripe_subscription_id: subscription["id"]) if offer.stripe_subscription_id.blank? && subscription["id"].present?

      case subscription["status"]
      when "active", "trialing"
        offer.update!(status: "active", activated_at: offer.activated_at || Time.current, canceled_at: nil)
      when "past_due", "unpaid"
        offer.update!(status: "past_due")
      when "canceled", "incomplete_expired"
        offer.update!(status: "canceled", canceled_at: Time.current)
      end
    end

    def self.offer_from(metadata)
      id = metadata&.[]("seller_plan_offer_id")
      return nil if id.blank?

      SellerPlanOffer.find_by(id:)
    end

    private_class_method :activate_from_checkout, :sync_subscription, :offer_from
  end
end
