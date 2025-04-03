# frozen_string_literal: true

# Email provider-agnostic service to handle email event info.
# The logic should not handle any email provider (Sendgrid, Resend) specific logic.
# For that, user EmailEventInfo subclasses (SendgridEventInfo, ResendEventInfo).
#
class HandleEmailEventInfo
  def self.perform(email_event_info)
    if email_event_info.for_installment_email?
      HandleEmailEventInfo::ForInstallmentEmail.perform(email_event_info)
    elsif email_event_info.for_receipt_email?
      HandleEmailEventInfo::ForReceiptEmail.perform(email_event_info)
    elsif email_event_info.for_abandoned_cart_email?
      HandleEmailEventInfo::ForAbandonedCartEmail.perform(email_event_info)
    end
  end
end
