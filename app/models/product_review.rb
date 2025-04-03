# frozen_string_literal: true

class ProductReview < ApplicationRecord
  include ExternalId, Deletable

  PRODUCT_RATING_RANGE = (1..5)
  REVIEW_REMINDER_DELAY = 5.days
  REVIEW_REMINDER_PHYSICAL_DELAY = 90.days
  RestrictedOperationError = Class.new(StandardError)

  belongs_to :link, optional: true
  belongs_to :purchase, optional: true
  has_one :response, class_name: "ProductReviewResponse"
  has_many :videos, dependent: :destroy, class_name: "ProductReviewVideo"

  validates_presence_of :purchase
  validates_presence_of :link
  validates_uniqueness_of :purchase_id
  validates_inclusion_of :rating, in: PRODUCT_RATING_RANGE, message: "Invalid product rating."

  validate :message_cannot_contain_adult_keywords, if: :message_changed?

  before_create do
    next if purchase.allows_review_to_be_counted?
    raise RestrictedOperationError.new("Creating a review for an invalid purchase is not handled")
  end
  before_update do
    next if !rating_changed? || purchase.allows_review_to_be_counted?
    raise RestrictedOperationError.new("A rating on a invalid purchase can't be changed")
  end
  before_destroy do
    raise RestrictedOperationError.new("Updating stats when destroying review is not handled")
  end
  after_save :update_product_review_stat

  private
    def update_product_review_stat
      return if rating_previous_change.nil?
      link.update_review_stat_via_rating_change(*rating_previous_change)
    end

    def message_cannot_contain_adult_keywords
      errors.add(:base, "Adult keywords are not allowed") if AdultKeywordDetector.adult?(message)
    end
end
