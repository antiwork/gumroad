# frozen_string_literal: true

class HandleHelperEventWorker
  include Sidekiq::Job

  sidekiq_options retry: 3, queue: :default

  RECENT_PURCHASE_PERIOD = 1.year
  HELPER_EVENTS = %w[conversation.created]
  # Automated Stripe notification emails (e.g. Radar "suspected fraudulent payment"
  # alerts) are not from a customer, so the buyer-unblock flow below has nothing to
  # do for them. Radar fraud signals are handled by the Stripe webhook processor
  # (StripeChargeRadarProcessor); the conversation itself is left for support triage.
  STRIPE_NOTIFICATION_SENDER = "notifications@stripe.com"

  def perform(event, payload)
    return unless event.in?(HELPER_EVENTS)

    conversation_id = payload["conversation_id"]
    email_id = payload["email_id"]
    email = payload["email_from"]

    Rails.logger.info("Received Helper event '#{event}' for conversation #{conversation_id}")
    if email.blank?
      Rails.logger.warn("Empty email in conversation #{conversation_id}")
      return
    end

    return if email == STRIPE_NOTIFICATION_SENDER

    purchase = HelperUserInfoService.new(email:, recent_purchase_period: RECENT_PURCHASE_PERIOD).recent_purchase

    unblock_email_service = Helper::UnblockEmailService.new(conversation_id:, email_id:, email:)
    unblock_email_service.recent_blocked_purchase = purchase if purchase.try(:buyer_blocked?) && (purchase.stripe_error_code || purchase.error_code).in?(PurchaseErrorCode::UNBLOCK_BUYER_ERROR_CODES)
    unblock_email_service.process
    if unblock_email_service.replied?
      Rails.logger.info("Replied to Helper conversation #{conversation_id} from UnblockEmailService")
    end
  end
end
