# frozen_string_literal: true

module Purchase::Reviews
  extend ActiveSupport::Concern

  included do
    COUNTS_REVIEWS_STATES = %w[successful gift_receiver_purchase_successful not_charged]

    has_one :product_review
    after_save :update_product_review_stat

    # Important: The logic needs to be the same as the one in `#allows_review_to_be_counted?`
    scope :allowing_reviews_to_be_counted, -> {
      where(purchase_state: COUNTS_REVIEWS_STATES).
        exclude_not_charged_except_free_trial.
        not_fully_refunded.
        not_chargedback.
        not_subscription_or_original_purchase.
        not_is_gift_sender_purchase.
        not_should_exclude_product_review.
        not_access_revoked_or_is_paid.
        not_is_bundle_purchase.
        not_is_commission_completion_purchase
    }
  end

  def original_product_review
    purchase = is_gift_sender_purchase? ? gift_given&.giftee_purchase : self
    purchase&.true_original_purchase&.product_review
  end

  def post_review(rating, message = nil)
    review = original_product_review
    if review.present?
      review.with_lock do
        review.update!(rating:, message:)
      end
      true
    elsif true_original_purchase.allows_review_to_be_counted?
      add_review!(rating, message)
      true
    else
      false
    end
  end

  def add_review!(rating, message = nil)
    review = ProductReview.create!(link:, purchase: true_original_purchase, rating:, message:)

    return if review.link.user.disable_reviews_email?
    ContactingCreatorMailer.review_submitted(review.id).deliver_later
  end

  # Important: The logic needs to be the same as the one in the scope `allowing_reviews_to_be_counted`
  def allows_review_to_be_counted?
    allows_reviews(permit_recurring_charges: false)
  end

  def allows_review?
    allows_reviews(permit_recurring_charges: true)
  end

  private
    def allows_reviews(permit_recurring_charges:)
      allowed = purchase_state.in?(COUNTS_REVIEWS_STATES)
      allowed &= !should_exclude_product_review?
      allowed &= !not_charged_and_not_free_trial?
      allowed &= not_is_gift_sender_purchase
      allowed &= !stripe_refunded?
      allowed &= chargeback_date.nil?
      allowed &= subscription_id.nil? || is_original_subscription_purchase? unless permit_recurring_charges
      allowed &= !is_access_revoked || paid?
      allowed &= not_is_bundle_purchase
      allowed &= not_is_commission_completion_purchase
      allowed
    end

    def update_product_review_stat
      return if saved_changes.blank? || original_product_review.blank? || true_original_purchase != self
      link.update_review_stat_via_purchase_changes(saved_changes, product_review: original_product_review)
    end
end
