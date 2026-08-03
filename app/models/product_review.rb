# frozen_string_literal: true

class ProductReview < ApplicationRecord
  include ExternalId, Deletable

  PRODUCT_RATING_RANGE = (1..5)
  REVIEW_REMINDER_DELAY = 5.days
  REVIEW_REMINDER_PHYSICAL_DELAY = 90.days
  # How long a message-less review waits before the seller is told about it. The rating autosave
  # creates the row the moment a star is tapped, usually a minute or two before the buyer submits
  # their text (gumroad-private#1783) — notifying on create meant the email routinely quoted
  # nothing. The window only has to cover taps that never become a submit; a message arriving at
  # any point emails immediately and cancels the delayed render.
  SELLER_NOTIFICATION_DELAY = 5.minutes
  RestrictedOperationError = Class.new(StandardError)

  belongs_to :link, optional: true
  belongs_to :purchase, optional: true
  has_one :response, class_name: "ProductReviewResponse"

  has_many :videos, dependent: :destroy, class_name: "ProductReviewVideo"
  has_many :alive_videos, -> { alive }, class_name: "ProductReviewVideo"
  has_one :approved_video, -> { alive.approved.latest }, class_name: "ProductReviewVideo"
  has_one :pending_video, -> { alive.pending_review.latest }, class_name: "ProductReviewVideo"
  has_one :editable_video, -> { alive.editable.latest }, class_name: "ProductReviewVideo"

  scope :visible_on_product_page,
        -> {
          left_joins(:approved_video)
            .where("product_reviews.has_message = true OR product_review_videos.id IS NOT NULL")
        }

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

  after_create_commit :notify_seller
  # The rating autosave creates the row before the buyer has typed, so the message arrives as an
  # update. Scoped to the blank→present transition: edits of existing text stay silent, and a
  # rating-only change never fires this.
  after_update_commit :notify_seller, if: -> { saved_change_to_message? && saved_change_to_message.first.blank? && message.present? }

  private
    def update_product_review_stat
      return if rating_previous_change.nil?
      link.update_review_stat_via_rating_change(*rating_previous_change)
    end

    def message_cannot_contain_adult_keywords
      errors.add(:base, "Adult keywords are not allowed") if AdultKeywordDetector.adult?(message)
    end

    def notify_seller
      return if link.user.disable_reviews_email?

      if message.present?
        ContactingCreatorMailer.review_submitted(id).deliver_later
      else
        # Delayed so a buyer who taps stars first gets one email with their text in it (the
        # blank→present update above owns that send; the mailer skips this render when a message
        # has arrived by then). Only a review that stays message-less emails star-only.
        ContactingCreatorMailer.review_submitted(id, skip_if_message_present: true)
          .deliver_later(wait: SELLER_NOTIFICATION_DELAY)
      end
    end
end
