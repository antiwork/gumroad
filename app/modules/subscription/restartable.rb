# frozen_string_literal: true

module Subscription::Restartable
  def restartable_for_product_and_buyer(product:, buyer:)
    return nil unless product.is_recurring_billing && product.alive?

    where(link_id: product.id)
      .where(ended_at: nil)
      .where(user_id: buyer.id)
      .where.not(deactivated_at: nil)
      .not_is_test_subscription
      .not_cancelled_by_admin
      .order(created_at: :desc)
      .first
  end

  def restartable_for_product_and_email(product:, email:)
    return nil unless product.is_recurring_billing && product.alive?

    where(link_id: product.id)
      .where(ended_at: nil)
      .joins(:original_purchase)
      .where(purchases: { email: email.to_s.downcase.strip })
      .where.not(deactivated_at: nil)
      .not_is_test_subscription
      .not_cancelled_by_admin
      .order(created_at: :desc)
      .first
  end

  # Every deactivated subscription the buyer holds for the product, including the ones
  # `restartable_for_*` skips (ended, cancelled by an admin).
  def lapsed_for_product_and_buyer(product:, buyer:)
    return none unless product.is_recurring_billing

    where(link_id: product.id)
      .where(user_id: buyer.id)
      .where.not(deactivated_at: nil)
      .not_is_test_subscription
  end

  def lapsed_for_product_and_email(product:, email:)
    return none unless product.is_recurring_billing

    where(link_id: product.id)
      .joins(:original_purchase)
      .where(purchases: { email: email.to_s.downcase.strip })
      .where.not(deactivated_at: nil)
      .not_is_test_subscription
  end

  def active_for_product_and_buyer(product:, buyer:)
    return nil unless product.is_recurring_billing

    where(link_id: product.id)
      .where(ended_at: nil)
      .where(failed_at: nil)
      .where("cancelled_at IS NULL OR cancelled_at > ?", Time.current)
      .where(user_id: buyer.id)
      .not_is_test_subscription
      .lock
      .first
  end

  def active_for_product_and_email(product:, email:)
    return nil unless product.is_recurring_billing

    where(link_id: product.id)
      .where(ended_at: nil)
      .where(failed_at: nil)
      .where("cancelled_at IS NULL OR cancelled_at > ?", Time.current)
      .joins(:original_purchase)
      .where(purchases: { email: email.to_s.downcase.strip })
      .not_is_test_subscription
      .lock
      .first
  end
end
