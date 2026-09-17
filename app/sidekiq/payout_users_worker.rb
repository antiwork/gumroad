# frozen_string_literal: true

class PayoutUsersWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default, lock: :until_executed

  def perform(date_string, processor_type, user_ids, payout_type = Payouts::PAYOUT_TYPE_STANDARD, retrying = false)
    PayoutUsersService.new(date_string:,
                           processor_type:,
                           user_ids:,
                           payout_type:,
                           retrying:).process
  end
end
