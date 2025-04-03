# frozen_string_literal: true

class RetryFailedPaypalPayoutsWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical, lock: :until_executed

  def perform
    payout_period_end_date = User::PayoutSchedule.manual_payout_end_date
    failed_payments_users = User.joins(:payments)
                                .where({
                                         payments: {
                                           state: "failed",
                                           failure_reason: nil,
                                           processor: PayoutProcessorType::PAYPAL,
                                           payout_period_end_date:
                                         }
                                       })
                                .uniq
    return if failed_payments_users.empty?

    Rails.logger.info("RETRY FAILED PAYOUTS PAYPAL: #{payout_period_end_date} (Started)")

    Payouts.create_payments_for_balances_up_to_date_for_users(payout_period_end_date, PayoutProcessorType::PAYPAL, failed_payments_users, perform_async: true, retrying: true)

    Rails.logger.info("RETRY FAILED PAYOUTS PAYPAL: #{payout_period_end_date} (Finished)")
  end
end
