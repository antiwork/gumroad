# frozen_string_literal: true

class ProductReview < ApplicationRecord
  include ExternalId, Deletable

  PRODUCT_RATING_RANGE = (1..5)
  REVIEW_REMINDER_DELAY = 5.days
  REVIEW_REMINDER_PHYSICAL_DELAY = 90.days
  # How long a rating-only review waits before its seller notification goes out, so a buyer who
  # tapped a star and is still typing gets their text into the same email. See `notify_seller`.
  RATING_AUTOSAVE_GRACE = 30.minutes
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

  after_commit :notify_seller

  private
    def update_product_review_stat
      return if rating_previous_change.nil?
      link.update_review_stat_via_rating_change(*rating_previous_change)
    end

    def message_cannot_contain_adult_keywords
      errors.add(:base, "Adult keywords are not allowed") if AdultKeywordDetector.adult?(message)
    end

    # Notification timing is the whole point of this method (gumroad-private#1783). The buyer's
    # rating autosaves 500ms after they tap a star (`autosaveRating` in ReviewForm.tsx), so the
    # create commit almost always lands before they have typed the review — notifying there emailed
    # sellers a star-only review that in fact had text. Notifying on every save instead would
    # re-email on later edits.
    #
    # So: text present means the buyer is done, send now. A rating-only create might still be
    # mid-typing, so defer past the autosave window; `review_submitted` reloads the review at
    # delivery time, so if text arrives in the window that send carries it.
    def notify_seller
      return if link.user.disable_reviews_email?
      return unless message.present? || previously_new_record?
      return unless claim_seller_notification!

      if message.present?
        ContactingCreatorMailer.review_submitted(id).deliver_later
      else
        ContactingCreatorMailer.review_submitted(id).deliver_later(wait: RATING_AUTOSAVE_GRACE)
      end
    end

    # One notification per review, claimed rather than checked: the autosave create and the buyer's
    # submit can commit close enough together to both pass a plain `seller_notified_at.nil?` read.
    # The UPDATE only matches while the column is still NULL, so exactly one caller wins.
    def claim_seller_notification!
      now = Time.current
      claimed = self.class.unscoped.where(id:, seller_notified_at: nil).update_all(seller_notified_at: now) == 1
      self[:seller_notified_at] = now if claimed
      claimed
    end
end
