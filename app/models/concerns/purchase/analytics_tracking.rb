# frozen_string_literal: true

module Purchase::AnalyticsTracking
  extend ActiveSupport::Concern

  included do
    after_commit :track_purchase_event, on: :create
    after_commit :track_state_change, on: :update, if: :saved_change_to_state?
  end

  def track_conversion_event
    return if is_test_purchase?

    AnalyticsTracker.track_conversion(
      user_id: buyer_user_id,
      product_id: link_id,
      amount: price_cents,
      currency: link.price_currency_type
    )
  end

  def track_refund_event
    return if is_test_purchase?

    AnalyticsTracker.track_refund(
      user_id: buyer_user_id,
      product_id: link_id,
      amount: amount_refunded_cents,
      currency: link.price_currency_type
    )
  end

  def update_creator_analytics_cache(force: false)
    return if is_test_purchase?

    if force || should_update_analytics_cache?
      CreatorAnalyticsCacheWorker.perform_async(seller_id)
    end
  end

  private

  def track_purchase_event
    return if is_test_purchase?

    case state
    when "successful", "not_charged"
      track_conversion_event
    when "failed"
      track_failed_purchase_event
    end
  end

  def track_state_change
    return if is_test_purchase?

    case state
    when "successful", "not_charged"
      track_conversion_event if state_previously_changed?
    when "failed"
      track_failed_purchase_event if state_previously_changed?
    end
  end

  def track_failed_purchase_event
    AnalyticsTracker.track_failed_purchase(
      product_id: link_id,
      error_code: error_code,
      failure_reason: failure_reason
    )
  end

  def should_update_analytics_cache?
    successful? || stripe_refunded_changed? || chargedback_changed?
  end

  def buyer_user_id
    User.find_by(email: email)&.id
  end
end
