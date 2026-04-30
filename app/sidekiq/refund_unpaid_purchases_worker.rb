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

    admin = User.find(admin_user_id)
    user.comments.create!(
      author_id: admin.id,
      author_name: admin.name_or_username,
      comment_type: Comment::COMMENT_TYPE_REFUND_BALANCE,
      content: "Refund balance initiated by #{admin.name_or_username}."
    )
  end
end
