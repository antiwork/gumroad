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
      email_info.mark_delivered!(email_event_info.created_at)
    when EmailEventInfo::EVENT_OPENED
      email_info.mark_opened!(email_event_info.created_at)
    when EmailEventInfo::EVENT_COMPLAINED
      unless email_event_info.email_provider == MailerInfo::EMAIL_PROVIDER_RESEND
        Purchase.find_by(id: email_event_info.purchase_id)&.unsubscribe_buyer
      end
    end
  end

  private
    # We create these records when sending emails so we shouldn't really need to create them again here.
    # However, this code needs to stay so as to support events which are triggered on emails which were sent before
    # the code to create these records was in place. From our investigation, we saw that we still receive events
    # for ancient purchases.
    def find_or_initialize_customer_email_info(email_event_info)
      if email_event_info.charge_id.present?
        CustomerEmailInfo.find_or_initialize_for_charge(
          charge_id: email_event_info.charge_id,
          email_name: email_event_info.mailer_method
        )
      else
        CustomerEmailInfo.find_or_initialize_for_purchase(
          purchase_id: email_event_info.purchase_id,
          email_name: email_event_info.mailer_method
        )
      end
    end
end
