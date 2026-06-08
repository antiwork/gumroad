# frozen_string_literal: true

class SendStripeBalanceCheckNotificationJob
  include Sidekiq::Job
  include CurrencyHelper
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform
    return unless Rails.env.production?

    balance_check = StripeBalanceCheckService.new

    $redis.set(RedisKey.stripe_balance_topup_needed, balance_check.topup_needed?)

    return unless balance_check.topup_needed?

    notification_msg = "Stripe balance needs to be #{formatted_dollar_amount(balance_check.required_balance_cents)} " \
                       "(#{formatted_dollar_amount(balance_check.upcoming_payouts_cents)} for upcoming payouts + " \
                       "#{formatted_dollar_amount(balance_check.minimum_balance_cents)} Stripe minimum balance) " \
                       "to pay out all creators.\n" \
                       "Current Stripe balance is #{formatted_dollar_amount(balance_check.current_balance_cents)}.\n" \
                       "A top-up of #{formatted_dollar_amount(balance_check.topup_amount_cents)} is needed."

    InternalNotificationWorker.perform_async("payments",
                                             "Stripe Balance Check",
                                             notification_msg,
                                             "red")
  end
end
