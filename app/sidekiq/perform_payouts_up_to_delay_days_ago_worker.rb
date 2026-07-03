# frozen_string_literal: true

class PerformPayoutsUpToDelayDaysAgoWorker
  include Sidekiq::Job
  # retry: 3 (was 0): with no retries, a single transient
  # ActiveRecord::StatementTimeout on the `holding_balance` query sends the whole weekly
  # batch straight to the dead set with no alert, leaving every seller in the affected
  # bucket unpaid until the next weekly run. Retrying is safe: per-user payout jobs are
  # deduplicated by their `until_executed` lock while queued, and once a user's balances
  # leave `unpaid`, Payouts.create_payment no-ops for that user.
  sidekiq_options retry: 3, queue: :critical, lock: :until_executed

  sidekiq_retries_exhausted do |job, exception|
    payout_processor_type, bank_account_types = job["args"]
    AccountingMailer.payout_batch_failed(payout_processor_type, bank_account_types, exception.class.name, exception.message).deliver_later
    ErrorNotifier.notify(exception, payout_processor_type:, bank_account_types:)
  end

  def perform(payout_processor_type, bank_account_types = nil)
    # Fan a multi-bank-type batch out into one job per bank account type. Processing the types
    # sequentially inside a single job meant one slow `holding_balance` query aborted every
    # remaining type's payouts along with it; isolated jobs give each type its own statement
    # budget and its own retries.
    if bank_account_types.is_a?(Array) && bank_account_types.many?
      bank_account_types.each { |bank_account_type| self.class.perform_async(payout_processor_type, [bank_account_type]) }
      Rails.logger.info("AUTOMATED PAYOUTS: #{payout_processor_type} fanned out to #{bank_account_types.size} per-bank-account-type jobs: #{bank_account_types}")
      return
    end

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
