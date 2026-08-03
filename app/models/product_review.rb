# frozen_string_literal: true

class ProductReview < ApplicationRecord
  include ExternalId, Deletable

  PRODUCT_RATING_RANGE = (1..5)
  REVIEW_REMINDER_DELAY = 5.days
  REVIEW_REMINDER_PHYSICAL_DELAY = 90.days
  # How long a message-less review waits before the seller is told about it. The rating autosave
  # creates the row the moment a star is tapped, usually a minute or two before the buyer submits
  # their text (gumroad-private#1783) — notifying on create meant the email routinely quoted
  # nothing. The window only has to cover taps that never become a submit; a message arriving
  # before the seller has been told emails immediately and cancels the delayed render.
  SELLER_NOTIFICATION_DELAY = 5.minutes

  # How long a render holds the seller's notice before it has to say what happened to it. It only has
  # to cover handing one message to the delivery method; expiring is the backstop for a render that
  # dies before it can settle. It is not evidence the seller was told — `seller_notified_at` is —
  # which is why a claim can expire without costing the notice.
  SELLER_NOTIFICATION_CLAIM_TTL = 10.minutes

  # Release only the claim this render holds. An absent key means ours already expired, so a DEL
  # would be a no-op; a different value means a successor claimed behind us and deleting it would
  # let a third render send a duplicate.
  RELEASE_SELLER_NOTIFICATION_IF_HELD = <<~LUA
    if redis.call('GET', KEYS[1]) == ARGV[1] then
      return redis.call('DEL', KEYS[1])
    end
    return 0
  LUA

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

  after_create_commit :notify_seller_of_new_review
  # The rating autosave creates the row before the buyer has typed, so the message arrives as an
  # update. Scoped to the blank→present transition: edits of existing text stay silent, and a
  # rating-only change never fires this. A distinct method name is load-bearing — Rails registers
  # `after_commit` callbacks by method name, so reusing the create callback's name here would
  # silently replace it.
  after_update_commit :notify_seller_of_arrived_message, if: -> { saved_change_to_message? && saved_change_to_message.first.blank? && message.present? }

  def seller_notified? = seller_notified_at.present?

  # Takes the seller's one notice for this review and returns the token proving this render holds
  # it, or nil when another render does. One write rather than a read followed by one: the delayed
  # message-less render and the blank→present arrival can overlap, and both reading an absent claim
  # would both send.
  def claim_seller_notification
    token = SecureRandom.hex(16)
    claimed = $redis.set(seller_notification_claim_key, token, nx: true, ex: SELLER_NOTIFICATION_CLAIM_TTL.to_i)
    claimed ? token : nil
  end

  # Gives back a claim this render took and did not spend, so a retry of the same delivery — or the
  # other path, if it is still to come — can report the review instead of the notice being lost.
  def release_seller_notification_claim(token)
    return if token.blank?

    $redis.eval(RELEASE_SELLER_NOTIFICATION_IF_HELD, keys: [seller_notification_claim_key], argv: [token])
  end

  # Written once a message has actually been transmitted. Durable rather than a Redis key with a
  # lifetime, because the buyer can add their text at any point after the message-less render
  # already told the seller — an hour later or a week later — and that must not be a second email.
  def record_seller_notified!
    self.class.where(id:, seller_notified_at: nil).update_all(seller_notified_at: Time.current)
  end

  private
    def seller_notification_claim_key = RedisKey.product_review_seller_notified(id)

    def update_product_review_stat
      return if rating_previous_change.nil?
      link.update_review_stat_via_rating_change(*rating_previous_change)
    end

    def message_cannot_contain_adult_keywords
      errors.add(:base, "Adult keywords are not allowed") if AdultKeywordDetector.adult?(message)
    end

    def notify_seller_of_new_review
      return if link.user.disable_reviews_email?

      if message.present?
        ContactingCreatorMailer.review_submitted(id).deliver_later
      else
        # Delayed so a buyer who taps stars first gets one email with their text in it (the
        # blank→present update below wins the claim in `ContactingCreatorMailer#review_submitted`
        # when the buyer's text has arrived by then). Only a review that stays message-less emails
        # star-only.
        ContactingCreatorMailer.review_submitted(id).deliver_later(wait: SELLER_NOTIFICATION_DELAY)
      end
    end

    def notify_seller_of_arrived_message
      return if link.user.disable_reviews_email?
      # A buyer who comes back well after the message-less render already reported the review is
      # editing a review the seller has been told about, not submitting a new one. The render
      # re-checks this too; this only saves enqueuing a job that would decide the same thing.
      return if seller_notified?

      ContactingCreatorMailer.review_submitted(id).deliver_later
    end
end
