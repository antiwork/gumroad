# frozen_string_literal: true

class SendPaypalTopupNotificationJob
  include Sidekiq::Job
  include CurrencyHelper
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform(notify_only_if_topup_needed = false)
    return unless Rails.env.production?

    payout_amount_cents = Balance
                            .unpaid
                            .where(user_id: Payment
                                              .where("created_at > ?", 1.month.ago)
                                              .where(processor: "paypal")
                                              .select(:user_id))
                            .where("date <= ?", User::PayoutSchedule.next_scheduled_payout_date)
                            .sum(:amount_cents)

    current_balance_cents = PaypalPayoutProcessor.current_paypal_balance_cents

    topup_amount_in_transit_cents = PaypalPayoutProcessor.topup_amount_in_transit * 100
    topup_amount_cents = payout_amount_cents - current_balance_cents - topup_amount_in_transit_cents

    topup_needed = topup_amount_cents > 0
    return if notify_only_if_topup_needed && !topup_needed

    notification_msg = "PayPal balance needs to be #{formatted_dollar_amount(payout_amount_cents)} by Friday to payout all creators.\n"\
                       "Current PayPal balance is #{formatted_dollar_amount(current_balance_cents)}.\n"

    notification_msg += "Top-up amount in transit is #{formatted_dollar_amount(topup_amount_in_transit_cents)}.\n" if topup_amount_in_transit_cents > 0

    notification_msg += if topup_needed
      "A top-up of #{formatted_dollar_amount(topup_amount_cents)} is needed."
    else
      "No more top-up required."
    end

    SlackMessageWorker.perform_async("payments",
                                     "PayPal Top-up",
                                     notification_msg,
                                     topup_needed ? "red" : "green")
  end
end
