# frozen_string_literal: true

class SendPaypalTopupNotificationJob
  include Sidekiq::Job
  include CurrencyHelper
  sidekiq_options retry: 1, queue: :default, lock: :until_executed, on_conflict: :replace

  def perform(notify_only_if_topup_needed = false)
    return unless Rails.env.production?

    balance_check = PaypalBalanceCheckService.new

    $redis.set(RedisKey.paypal_topup_needed, balance_check.topup_needed?)

    return if notify_only_if_topup_needed && !balance_check.topup_needed?

    notification_msg = "PayPal balance needs to be #{formatted_dollar_amount(balance_check.payout_amount_cents)} by Friday to payout all creators.\n"\
                       "Current PayPal balance is #{formatted_dollar_amount(balance_check.current_balance_cents)}.\n"

    notification_msg += "Top-up amount in transit is #{formatted_dollar_amount(balance_check.topup_in_transit_cents)}.\n" if balance_check.topup_in_transit_cents > 0

    notification_msg += if balance_check.topup_needed?
      "A top-up of #{formatted_dollar_amount(balance_check.topup_amount_cents)} is needed."
    else
      "No more top-up required."
    end

    SlackMessageWorker.perform_async("payments",
                                     "PayPal Top-up",
                                     notification_msg,
                                     balance_check.topup_needed? ? "red" : "green")
  end
end
