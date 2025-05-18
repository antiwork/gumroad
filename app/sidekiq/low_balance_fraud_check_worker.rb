# frozen_string_literal: true

class LowBalanceFraudCheckWorker
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform(purchase_id)
    creator = Purchase.find(purchase_id).seller
    creator.check_for_low_balance_and_probate(purchase_id)
  end
end
