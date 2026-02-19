# frozen_string_literal: true

module Subscription::Restartable
  def restartable_for_product_and_buyer(product:, buyer:)
    return nil unless product.is_recurring_billing

    where(link_id: product.id)
      .where(ended_at: nil)
      .where(user_id: buyer.id)
      .where.not(deactivated_at: nil)
      .not_cancelled_by_admin
      .order(created_at: :desc)
      .first
  end

  def restartable_for_product_and_email(product:, email:)
    return nil unless product.is_recurring_billing

    where(link_id: product.id)
      .where(ended_at: nil)
      .joins(:original_purchase)
      .where(purchases: { email: email.to_s.downcase.strip })
      .where.not(deactivated_at: nil)
      .not_cancelled_by_admin
      .order(created_at: :desc)
      .first
  end

  def active_for_product_and_buyer(product:, buyer:)
    return nil unless product.is_recurring_billing

    where(link_id: product.id)
      .where(ended_at: nil)
      .where(failed_at: nil)
      .where("cancelled_at IS NULL OR cancelled_at > ?", Time.current)
      .where(user_id: buyer.id)
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
      .lock
      .first
  end
end
