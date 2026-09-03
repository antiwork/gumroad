# frozen_string_literal: true

class HandleEmailEventInfo::ForInstallmentEmail
  attr_reader :email_event_info

  def self.perform(email_event_info)
    new(email_event_info).perform
  end

  def initialize(email_event_info)
    @email_event_info = email_event_info
  end

  def perform
    case email_event_info.type
    when EmailEventInfo::EVENT_BOUNCED
      handle_bounce_event!
    when EmailEventInfo::EVENT_DELIVERED
      handle_delivered_event!
    when EmailEventInfo::EVENT_OPENED
      handle_open_event!
    when EmailEventInfo::EVENT_CLICKED
      handle_click_event!
    when EmailEventInfo::EVENT_COMPLAINED
      unless email_event_info.email_provider == MailerInfo::EMAIL_PROVIDER_RESEND
        handle_spamreport_event!
      end
    end
  end

  private
    def handle_bounce_event!
      pull_creator_contacting_customers_email_info(email_event_info)&.mark_bounced!
    end

    def handle_delivered_event!
      email_info = pull_creator_contacting_customers_email_info(email_event_info)
      return if email_info.blank? || email_info.already_delivered?

      email_info.mark_delivered!(email_event_info.created_at)
    end

    def handle_open_event!
      EmailEngagementDynamoStore.record_open(**dynamo_engagement_attributes)

      email_info = pull_creator_contacting_customers_email_info(email_event_info)
      email_info.mark_opened!(email_event_info.created_at) if email_info.present? && !email_info.already_opened?

      update_installment_cache(email_event_info.installment_id, :unique_open_count)
    end

    def handle_click_event!
      return if email_event_info.click_url_as_engagement_key.blank?

      EmailEngagementDynamoStore.record_click(**dynamo_engagement_attributes, click_url: email_event_info.click_url_as_engagement_key)
      update_installment_cache(email_event_info.installment_id, :unique_click_count)
      update_installment_cache(email_event_info.installment_id, :unique_open_count)

      email_info = pull_creator_contacting_customers_email_info(email_event_info)
      email_info.mark_opened!(email_event_info.created_at) if email_info&.persisted? && !email_info.already_opened?
    end

    def handle_spamreport_event!
      purchase = Purchase.find_by(id: email_event_info.purchase_id)

      if purchase.present?
        purchase.unsubscribe_buyer(reason: Purchase::CAN_CONTACT_REASON_SPAM_REPORT)
      else
        # Unsubscribe the follower
        seller_id = Installment.find(email_event_info.installment_id).seller_id
        Follower.unsubscribe(seller_id, email_event_info.email)
      end
    end

    def pull_creator_contacting_customers_email_info(email_event_info)
      purchase_id = email_event_info.purchase_id
      installment_id = email_event_info.installment_id
      email_name = nil
      if email_event_info.mailer_class_and_method.end_with?(EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD)
        email_name = EmailEventInfo::PURCHASE_INSTALLMENT_MAILER_METHOD
        email_info = CreatorContactingCustomersEmailInfo.where(purchase_id:, installment_id:).last
      elsif email_event_info.mailer_class_and_method.end_with?(EmailEventInfo::SUBSCRIPTION_INSTALLMENT_MAILER_METHOD)
        email_name = EmailEventInfo::SUBSCRIPTION_INSTALLMENT_MAILER_METHOD
        purchase_id = Subscription.find(email_event_info.purchase_id).original_purchase.id
        email_info = CreatorContactingCustomersEmailInfo.where(purchase_id:, installment_id:).last
      else
        return nil
      end

      # We create these records when sending emails so we shouldn't really need to create them again here.
      # However, this code needs to stay so as to support events which are triggered on emails which were sent before
      # the code to create these records was in place. From our investigation, we saw that we still receive events
      # for ancient purchases.
      email_info || CreatorContactingCustomersEmailInfo.new(purchase_id:, installment_id:, email_name:)
    end

    def update_installment_cache(installment_id, key)
      # DDB aggregates are live GetItem reads. Clear stale cache entries for
      # this event, but do not precompute counters from a discarded instance —
      # and do not SELECT installments just to build a key from the id.
      Installment.invalidate_engagement_cache(installment_id, key)
    end

    def dynamo_engagement_attributes
      {
        installment_id: email_event_info.installment_id,
        mailer_method: email_event_info.mailer_class_and_method,
        mailer_args: email_event_info.mailer_args,
      }
    end
end
