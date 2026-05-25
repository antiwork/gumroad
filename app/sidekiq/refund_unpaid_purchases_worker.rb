# frozen_string_literal: true

class RefundUnpaidPurchasesWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def self.lock_args(args)
    [args.first]
  end

  def self.unpaid_purchases_for(user)
    unpaid_balance_ids = user.balances.unpaid.select(:id)
    user.sales.where(purchase_success_balance_id: unpaid_balance_ids).successful.not_fully_refunded
  end

  def self.unpaid_balance_summary_for(user)
    refundable_amounts = unpaid_purchases_for(user)
      .left_joins(:refunds)
      .group("purchases.id", "purchases.price_cents", "purchases.gumroad_tax_cents")
      .pluck(Arel.sql(
               "COALESCE(purchases.price_cents, 0) + " \
               "COALESCE(purchases.gumroad_tax_cents, 0) - " \
               "COALESCE(SUM(refunds.amount_cents), 0) - " \
               "COALESCE(SUM(refunds.gumroad_tax_cents), 0)"
             ))

    {
      count: refundable_amounts.size,
      total_amount_cents: refundable_amounts.sum,
      currency: Currency::USD
    }
  end

  def perform(user_id, admin_user_id)
    user = User.find(user_id)
    return unless user.suspended?

    self.class.unpaid_purchases_for(user).ids.each do |purchase_id|
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
