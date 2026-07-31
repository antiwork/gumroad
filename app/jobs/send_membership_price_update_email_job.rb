# frozen_string_literal: true

class SendMembershipPriceUpdateEmailJob < ActiveJob::Base
  queue_as :low

  retry_on Net::OpenTimeout, Net::ReadTimeout, Net::SMTPServerBusy,
           wait: :polynomially_longer, attempts: 10

  def perform(subscription_plan_change_id, claim_id)
    subscription_plan_change = SubscriptionPlanChange.find(subscription_plan_change_id)
    return unless subscription_plan_change.start_price_change_notification_delivery(claim_id)

    subscription = subscription_plan_change.subscription
    # A crash after provider acceptance can duplicate this notice on retry, but confirming
    # earlier could silently authorize a price for an email that never left the queue.
    CustomerLowPriorityMailer.subscription_price_change_notification(
      subscription_id: subscription.id,
      new_price: subscription_plan_change.perceived_price_cents,
    ).deliver_now

    subscription_plan_change.confirm_price_change_notification(claim_id)
  end
end
