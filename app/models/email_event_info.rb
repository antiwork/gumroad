# frozen_string_literal: true

class EmailEventInfo
  RECEIPT_MAILER_METHOD = "receipt"
  PREORDER_RECEIPT_MAILER_METHOD = "preorder_receipt"
  PURCHASE_INSTALLMENT_MAILER_METHOD = "purchase_installment"
  FOLLOWER_INSTALLMENT_MAILER_METHOD = "follower_installment"
  DIRECT_AFFILIATE_INSTALLMENT_MAILER_METHOD = "direct_affiliate_installment"
  TRACKED_RECEIPT_MAILER_METHODS = [RECEIPT_MAILER_METHOD, PREORDER_RECEIPT_MAILER_METHOD]
  TRACKED_INSTALLMENT_MAILER_METHODS = [PURCHASE_INSTALLMENT_MAILER_METHOD, FOLLOWER_INSTALLMENT_MAILER_METHOD, DIRECT_AFFILIATE_INSTALLMENT_MAILER_METHOD]

  # We don't have this mailer class in the app now, but we use the class name for backwards compatibility in the data.
  CREATOR_CONTACTING_CUSTOMERS_MAILER_CLASS = "CreatorContactingCustomersMailer"

  # Subset of events from:
  # - https://docs.sendgrid.com/for-developers/tracking-events/event#event-objects
  # - https://resend.com/docs/dashboard/webhooks/event-types
  EVENTS = {
    bounced: {
      MailerInfo::EMAIL_PROVIDER_SENDGRID => "bounce",
      MailerInfo::EMAIL_PROVIDER_RESEND => "email.bounced"
    },
    delivered: {
      MailerInfo::EMAIL_PROVIDER_SENDGRID => "delivered",
      MailerInfo::EMAIL_PROVIDER_RESEND => "email.delivered"
    },
    opened: {
      MailerInfo::EMAIL_PROVIDER_SENDGRID => "open",
      MailerInfo::EMAIL_PROVIDER_RESEND => "email.opened"
    },
    clicked: {
      MailerInfo::EMAIL_PROVIDER_SENDGRID => "click",
      MailerInfo::EMAIL_PROVIDER_RESEND => "email.clicked"
    },
    complained: {
      MailerInfo::EMAIL_PROVIDER_SENDGRID => "spamreport",
      MailerInfo::EMAIL_PROVIDER_RESEND => "email.complained"
    }
  }.freeze
  EVENTS.keys.each do |event_type|
    const_set("EVENT_#{event_type.upcase}", event_type)
  end

  TRACKED_EVENTS = {
    MailerInfo::EMAIL_PROVIDER_SENDGRID => EVENTS.transform_values { |v| v[MailerInfo::EMAIL_PROVIDER_SENDGRID] },
    MailerInfo::EMAIL_PROVIDER_RESEND => EVENTS.transform_values { |v| v[MailerInfo::EMAIL_PROVIDER_RESEND] }
  }.freeze

  SUBSCRIPTION_INSTALLMENT_MAILER_METHOD = "subscription_installment"
  ABANDONED_CART_MAILER_METHOD = "abandoned_cart"
  CUSTOMER_MAILER = "CustomerMailer"

  attr_reader :mailer_method, :mailer_class, :installment_id, :click_url

  def click_url_as_mongo_key
    @_click_url_as_mongo_key ||= begin
      return if click_url.blank?
      return if unsubscribe_click? # Don't count unsubscribe clicks.

      if attachment_click?
        CreatorEmailClickEvent::VIEW_ATTACHMENTS_URL
      else
        # Encoding "." is necessary because Mongo doesn't allow periods as key names.
        click_url.gsub(/\./, "&#46;")
      end
    end
  end

  def for_installment_email?
    installment_id.present?
  end

  def for_receipt_email?
    mailer_class == CUSTOMER_MAILER &&
    mailer_method.in?(TRACKED_RECEIPT_MAILER_METHODS)
  end

  def for_abandoned_cart_email?
    mailer_class == CUSTOMER_MAILER &&
    mailer_method == ABANDONED_CART_MAILER_METHOD
  end

  private
    # Indicates whether the recipient clicked on the download attachments link
    def attachment_click?
      click_url =~ %r{#{DOMAIN}/d/[a-z0-9]{32}}o
    end

    # The regex corresponds to possible ExternalIds, which are base64 encoded with urlsafe parameters (- and _ instead of + and /)
    # An ExternalId may also end in = or == (denotes padding)
    EXTERNAL_ID_PATTERN = "[\\w-]+={0,2}"
    private_constant :EXTERNAL_ID_PATTERN

    # Checks if the url is for unsubscribing or unfollowing.
    def unsubscribe_click?
      # These are three different paths that a user may click to unsubscribe.
      customer_path = URI::DEFAULT_PARSER.unescape(
        Rails.application.routes.url_helpers.unsubscribe_purchase_path(EXTERNAL_ID_PATTERN)
      )
      imported_customer_path = URI::DEFAULT_PARSER.unescape(
        Rails.application.routes.url_helpers.unsubscribe_imported_customer_path(EXTERNAL_ID_PATTERN)
      )
      follower_path = URI::DEFAULT_PARSER.unescape(
        Rails.application.routes.url_helpers.cancel_follow_path(EXTERNAL_ID_PATTERN)
      )
      click_url =~ /#{DOMAIN}(#{customer_path}|#{imported_customer_path}|#{follower_path})/
    end
end
