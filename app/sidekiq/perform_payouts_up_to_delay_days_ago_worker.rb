# frozen_string_literal: true

class PerformPayoutsUpToDelayDaysAgoWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical, lock: :until_executed

  def perform(payout_processor_type, bank_account_types = nil)
    payout_period_end_date = User::PayoutSchedule.next_scheduled_payout_end_date

    Rails.logger.info("AUTOMATED PAYOUTS: #{payout_period_end_date}, #{payout_processor_type}, #{bank_account_types} (Started)")

    if bank_account_types
      Payouts.create_payments_for_balances_up_to_date_for_bank_account_types(payout_period_end_date, payout_processor_type, bank_account_types)
    else
      Payouts.create_payments_for_balances_up_to_date(payout_period_end_date, payout_processor_type)
    end

    Rails.logger.info("AUTOMATED PAYOUTS: #{payout_period_end_date}, #{payout_processor_type} #{bank_account_types} (Finished)")
  end
end
