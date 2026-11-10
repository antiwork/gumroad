# frozen_string_literal: true

# A seller's request to publish a never-published draft at a later time. Created only while the
# :scheduled_product_publishing flag is on for the seller; an accepted schedule is honored after the flag
# is turned off. The row is the only trigger state: DispatchProductPublishSchedulesJob finds due rows
# every minute, so there is no per-schedule delayed job to go stale. Cancelling deletes the row, and
# so does a delivered success notice: a row that remains is pending or is a failure the seller must see.
class ProductPublishSchedule < ApplicationRecord
  FEATURE_FLAG = :scheduled_product_publishing
  MIN_LEAD_TIME = 5.minutes
  MAX_LATENESS = 5.minutes
  CLAIM_TIMEOUT = 15.minutes
  STATUSES = %w[scheduled publishing published failed].freeze
  LATE_MESSAGE = "We couldn't publish your product at the scheduled time, so it was left unpublished. Publish it from the editor when you're ready."
  AUTHORITY_REVOKED_MESSAGE = "The person who scheduled this product can no longer publish it, so it was left unpublished."
  GENERIC_FAILURE_MESSAGE = "We couldn't publish your product automatically. Review it and publish it from the editor."

  belongs_to :product, class_name: "Link"
  belongs_to :scheduled_by, class_name: "User"

  validates :status, inclusion: { in: STATUSES }
  validates :publish_at, presence: true

  scope :scheduled, -> { where(status: "scheduled") }
  scope :due, ->(now = Time.current) { scheduled.where(publish_at: ..now) }
  scope :stale_claims, ->(now = Time.current) { where(status: "publishing", claimed_at: ..(now - CLAIM_TIMEOUT)) }
  scope :notice_unsent, -> { where(status: %w[published failed], notice_sent_at: nil) }

  class Invalid < StandardError; end
  class Withdrawn < StandardError; end

  class << self
    def creation_enabled_for?(seller)
      Feature.active?(FEATURE_FLAG, seller)
    end

    # The product left the never-published draft state the schedule was accepted for.
    def withdrawn?(product)
      product.nil? || product.deleted_at.present? || !product.draft? || product.banned_at.present? || product.archived?
    end

    # A schedule the job has already claimed is left alone: the job re-checks the product itself.
    def cancel_pending!(product_id)
      scheduled.where(product_id:).delete_all
    end

    # `local_time` is wall-clock time in the seller's zone, e.g. "2026-12-01T09:30".
    def schedule!(product:, scheduled_by:, local_time:, now: Time.current)
      seller = product.user
      raise Invalid, "Scheduled publishing isn't available for your account yet." unless creation_enabled_for?(seller)

      publish_at = parse_local_time(local_time, seller)
      raise Invalid, "Choose a time at least #{MIN_LEAD_TIME.in_minutes.to_i} minutes from now." if publish_at < now + MIN_LEAD_TIME

      transaction do
        # Serializes concurrent requests for one product; the unique index is the backstop.
        product.lock!
        reason = ineligibility_reason(product)
        raise Invalid, reason if reason

        where(product_id: product.id, status: "failed").delete_all
        raise Invalid, "This product already has a schedule. Cancel it first." if exists?(product_id: product.id)

        create!(product:, scheduled_by:, publish_at:)
      end
    end

    def ineligibility_reason(product)
      return "Only products that have never been published can be scheduled." unless product.draft? && product.first_published_at.nil?
      # `purchase_disabled_at` is not a blocker: LinksController#create stamps it on every new draft.
      return "This product can't be scheduled." if product.deleted_at || product.banned_at || product.archived?
      return "Pre-orders can't be scheduled." if product.is_in_preorder_state
      return "Your account can't publish products right now." if product.user.suspended?

      product.publish_precheck_error
    end

    def parse_local_time(local_time, seller)
      zone = ActiveSupport::TimeZone[seller.timezone_id]
      # strptime rejects impossible dates (February 30) that Time.zone.parse rolls over without a message.
      naive = DateTime.strptime(local_time.to_s[0, 16].tr(" ", "T"), "%Y-%m-%dT%H:%M")
      zone.tzinfo.local_to_utc(Time.utc(naive.year, naive.month, naive.day, naive.hour, naive.min)).in_time_zone("UTC")
    rescue TZInfo::PeriodNotFound
      raise Invalid, "That time doesn't exist in #{zone.name} because clocks skip forward. Choose a different time."
    rescue TZInfo::AmbiguousTime
      raise Invalid, "That time happens twice in #{zone.name} because clocks go back. Choose a different time."
    rescue ArgumentError
      raise Invalid, "Enter a valid date and time."
    end
  end

  def local_time_label(time = publish_at)
    time.in_time_zone(ActiveSupport::TimeZone[product.user.timezone_id]).strftime("%B %-d, %Y at %-l:%M %p %Z")
  end

  # Short claim, then publish without holding any schedule lock. Returns the final status, or nil
  # when the row was not claimed or was removed.
  def run!(now: Time.current)
    return unless claim!(now)

    published = false
    fresh = Link.find_by(id: product_id)
    # The Link after_save cancellation only reaches unclaimed rows, and never sees an archive.
    return discard! if self.class.withdrawn?(fresh)
    return finish!("failed", LATE_MESSAGE) if now > publish_at + MAX_LATENESS
    return finish!("failed", AUTHORITY_REVOKED_MESSAGE) unless scheduler_authorized?(fresh)

    begin
      # A fresh instance, never reused after a failure: publish! assigns draft=false before it validates.
      # The block reruns the check under publish!'s product lock, which archive, delete and ban writes also take.
      fresh.publish! { raise Withdrawn if self.class.withdrawn?(Link.lock.find_by(id: product_id)) }
      published = true
      finish!("published")
    rescue Withdrawn
      discard!
    rescue Link::LinkInvalid, ActiveRecord::RecordInvalid => e
      finish!("failed", fresh.errors.full_messages.first.presence || e.message)
    end
  rescue StandardError => e
    # Infrastructure error: release the claim so the dispatcher tries again each minute until
    # MAX_LATENESS. After a publish the claim stays, and recover_stale_claim! records the outcome.
    # publish! can raise from an after_commit callback after the product is already live.
    published ||= Link.where(id: product_id, draft: false).exists?
    claimed.update_all(status: "scheduled", claimed_at: nil) unless published
    ErrorNotifier.notify(e, product_schedule_id: id)
    raise
  end

  # Called by the dispatcher for rows a dead worker left claimed.
  def recover_stale_claim!
    fresh = Link.find_by(id: product_id)
    if fresh && !fresh.draft? && fresh.deleted_at.nil?
      finish!("published")
    else
      finish!("failed", GENERIC_FAILURE_MESSAGE)
    end
  end

  private
    def claim!(now)
      # Rounded to the column precision, because `claimed` matches on the stored value.
      self.claimed_at = now.floor(6)
      self.class.due(now).where(id:).update_all(status: "publishing", claimed_at:, updated_at: now) == 1
    end

    # This instance's claim only: a row that was released and claimed again belongs to another job.
    def claimed
      self.class.where(id:, status: "publishing", claimed_at:)
    end

    def discard!
      claimed.delete_all
      nil
    end

    def finish!(outcome, failure_message = nil)
      finished = claimed.update_all(
        status: outcome,
        claimed_at: nil,
        published_at: (Time.current if outcome == "published"),
        failure_message: (ActionController::Base.helpers.strip_tags(failure_message).truncate(250) if failure_message),
        updated_at: Time.current
      )
      return if finished.zero?

      SendProductPublishScheduleNoticeJob.perform_async(id)
      outcome
    end

    def scheduler_authorized?(product)
      seller = product.user
      scheduled_by.alive? && !scheduled_by.suspended? && !seller.suspended? &&
        LinkPolicy.new(SellerContext.new(user: scheduled_by, seller:), product).publish?
    rescue ActiveRecord::RecordNotFound
      false
    end
end
