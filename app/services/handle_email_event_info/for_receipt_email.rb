# frozen_string_literal: true

class HandleEmailEventInfo::ForReceiptEmail
  attr_reader :email_event_info

  def self.perform(email_event_info)
    new(email_event_info).perform
  end

  def initialize(email_event_info)
    @email_event_info = email_event_info
  end

  def perform
    email_info = find_or_initialize_customer_email_info(email_event_info)

    case email_event_info.type
    when EmailEventInfo::EVENT_BOUNCED
      email_info.mark_bounced!
    when EmailEventInfo::EVENT_DELIVERED
      email_info.mark_delivered!(email_event_info.created_at) unless email_info.already_delivered?
    when EmailEventInfo::EVENT_OPENED
      email_info.mark_opened!(email_event_info.created_at) unless email_info.already_opened?
    when EmailEventInfo::EVENT_COMPLAINED
      unless email_event_info.email_provider == MailerInfo::EMAIL_PROVIDER_RESEND
        Purchase.find_by(id: email_event_info.purchase_id)
                &.unsubscribe_buyer(reason: Purchase::CAN_CONTACT_REASON_SPAM_REPORT)
      end
    end
  end

  private
    # We create these records when sending emails so we shouldn't really need to create them again here.
    # However, this code needs to stay so as to support events which are triggered on emails which were sent before
    # the code to create these records was in place. From our investigation, we saw that we still receive events
    # for ancient purchases.
    def find_or_initialize_customer_email_info(email_event_info)
      # `created_at` is the provider's event timestamp, which routes a late or
      # retried event to the send it actually describes.
      if email_event_info.charge_id.present?
        CustomerEmailInfo.find_or_initialize_for_charge(
          charge_id: email_event_info.charge_id,
          email_name: email_event_info.mailer_method,
          sent_before: email_event_info.created_at
        )
      else
        CustomerEmailInfo.find_or_initialize_for_purchase(
          purchase_id: email_event_info.purchase_id,
          email_name: email_event_info.mailer_method,
          sent_before: email_event_info.created_at
        )
      end
    end
end
