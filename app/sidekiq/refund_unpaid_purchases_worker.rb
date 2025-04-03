# frozen_string_literal: true

class RefundUnpaidPurchasesWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform(user_id, admin_user_id)
    user = User.find(user_id)
    return unless user.suspended?

    unpaid_balance_ids = user.balances.unpaid.ids
    user.sales.where(purchase_success_balance_id: unpaid_balance_ids).successful.not_fully_refunded.ids.each do |purchase_id|
      RefundPurchaseWorker.perform_async(purchase_id, admin_user_id)
    end
  end
end
