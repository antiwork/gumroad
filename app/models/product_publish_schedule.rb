# frozen_string_literal: true

# A seller's request to publish a never-published draft at a later time. Created only while the
# :scheduled_product_publishing flag is on for the seller; an accepted schedule is honored after the flag
# is turned off. The row is the source of truth: the Sidekiq job is a fast path and
# DispatchProductPublishSchedulesJob recovers lost jobs, stuck claims and unsent notices.
class ProductPublishSchedule < ApplicationRecord
  FEATURE_FLAG = :scheduled_product_publishing
  MIN_LEAD_TIME = 5.minutes
  MAX_LATENESS = 5.minutes
  CLAIM_TIMEOUT = 15.minutes
  STATUSES = %w[scheduled publishing published failed cancelled].freeze
  GENERIC_FAILURE_MESSAGE = "We couldn't publish your product automatically. Review it and publish it from the editor."

  belongs_to :product, class_name: "Link"
  belongs_to :scheduled_by, class_name: "User"

  validates :status, inclusion: { in: STATUSES }
  validates :publish_at, presence: true

  scope :scheduled, -> { where(status: "scheduled") }
  scope :due, ->(now = Time.current) { scheduled.where(publish_at: ..now) }
  scope :stale_claims, ->(now = Time.current) { where(status: "publishing", claimed_at: ..(now - CLAIM_TIMEOUT)) }

  class Invalid < StandardError; end

  class << self
    def creation_enabled_for?(seller)
      Feature.active?(FEATURE_FLAG, seller)
    end

    # Cancels a pending schedule from any route (manual publish, unpublish, delete, takedown). A schedule
    # already claimed by the job is left alone: the job re-checks the product itself.
    def cancel_pending!(product_id, reason:)
      scheduled.where(product_id:).update_all(
        status: "cancelled", cancellation_reason: reason, version: Arel.sql("version + 1"), updated_at: Time.current
      )
    end

    # `local_time` is wall-clock time in the seller's zone, e.g. "2026-12-01T09:30".
    def schedule!(product:, scheduled_by:, local_time:, now: Time.current)
      seller = product.user
      raise Invalid, "Scheduled publishing isn't available for your account yet." unless creation_enabled_for?(seller)

      publish_at = parse_local_time(local_time, seller)
      raise Invalid, "Choose a time at least #{MIN_LEAD_TIME.in_minutes.to_i} minutes from now." if publish_at < now + MIN_LEAD_TIME

      transaction do
        product.lock!
        reason = ineligibility_reason(product)
        raise Invalid, reason if reason

        schedule = find_or_initialize_by(product_id: product.id)
        raise Invalid, "This product is being published right now." if schedule.status == "publishing"

        schedule.assign_attributes(
          scheduled_by:, publish_at:, status: "scheduled", claimed_at: nil, published_at: nil, failure_message: nil,
          cancellation_reason: nil, success_notice_sent_at: nil, failure_notice_sent_at: nil, failure_dismissed_at: nil,
          version: schedule.version + 1
        )
        schedule.save!
        PublishScheduledProductJob.perform_at(publish_at, schedule.id, schedule.version)
        schedule
      end
    end

    def ineligibility_reason(product)
      return "Only products that have never been published can be scheduled." unless product.draft? && product.first_published_at.nil?
      return "This product can't be scheduled." if product.deleted_at || product.banned_at || product.purchase_disabled_at || product.archived?
      return "Pre-orders can't be scheduled." if product.is_in_preorder_state
      return "Your account can't publish products right now." if product.user.suspended?

      product.publish_precheck_error
    end

    def parse_local_time(local_time, seller)
      zone = ActiveSupport::TimeZone[seller.timezone_id]
      naive = Time.zone.parse(local_time.to_s) if local_time.present? && local_time.to_s.match?(/\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/)
      raise Invalid, "Enter a valid date and time." if naive.nil?

      begin
        utc = zone.tzinfo.local_to_utc(Time.utc(naive.year, naive.month, naive.day, naive.hour, naive.min))
      rescue TZInfo::PeriodNotFound
        raise Invalid, "That time doesn't exist in #{zone.name} because clocks skip forward. Choose a different time."
      rescue TZInfo::AmbiguousTime
        raise Invalid, "That time happens twice in #{zone.name} because clocks go back. Choose a different time."
      end
      utc.in_time_zone("UTC")
    end
  end

  def scheduled? = status == "scheduled"
  def active? = %w[scheduled publishing].include?(status)

  def local_time_label(time = publish_at)
    zone = ActiveSupport::TimeZone[product.user.timezone_id]
    time.in_time_zone(zone).strftime("%B %-d, %Y at %-l:%M %p %Z")
  end

  def local_input_value
    publish_at.in_time_zone(ActiveSupport::TimeZone[product.user.timezone_id]).strftime("%Y-%m-%dT%H:%M")
  end

  # Short claim, then publish without holding any schedule lock. Returns the final status.
  def run!(expected_version:, now: Time.current)
    return unless claim!(expected_version, now)

    if now > publish_at + MAX_LATENESS
      return finish!("failed", "We couldn't publish your product at the scheduled time, so it was left unpublished. Publish it from the editor when you're ready.")
    end

    fresh = Link.find_by(id: product_id)
    return finish!("cancelled", "deleted") if fresh.nil? || fresh.deleted_at
    return finish!("cancelled", "already_published") unless fresh.draft?
    return finish!("cancelled", "authority_revoked") unless scheduler_authorized?(fresh)

    begin
      # A fresh instance, never reused after a failure: publish! assigns draft=false before it validates.
      fresh.publish!
      finish!("published")
    rescue Link::LinkInvalid, ActiveRecord::RecordInvalid => e
      finish!("failed", fresh.errors.full_messages.first.presence || e.message)
    end
  rescue StandardError => e
    # Infrastructure error: release the claim so the Sidekiq retry (or the dispatcher) can take it again.
    self.class.where(id:, status: "publishing").update_all(status: "scheduled", claimed_at: nil)
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

  def cancel_for_revoked_authority!
    return unless scheduled?

    self.class.where(id:, status: "scheduled").update_all(status: "cancelled", cancellation_reason: "authority_revoked", version: version + 1)
  end

  def scheduler_authorized_now?
    product = Link.find_by(id: product_id)
    product.present? && scheduler_authorized?(product)
  end

  private
    def claim!(expected_version, now)
      claimed = self.class.where(id:, status: "scheduled", version: expected_version, publish_at: ..now)
        .update_all(status: "publishing", claimed_at: now, updated_at: now)
      claimed == 1 && reload
    end

    def finish!(outcome, detail = nil)
      attrs = { status: outcome, claimed_at: nil, updated_at: Time.current }
      case outcome
      when "published" then attrs[:published_at] = Time.current
      when "failed" then attrs[:failure_message] = ActionController::Base.helpers.strip_tags(detail.to_s).truncate(250)
      when "cancelled" then attrs[:cancellation_reason] = detail
      end
      self.class.where(id:, status: "publishing").update_all(attrs)
      reload
      SendProductPublishScheduleNoticeJob.perform_async(id)
      status
    end

    def scheduler_authorized?(product)
      seller = product.user
      scheduled_by.alive? && !seller.suspended? &&
        (scheduled_by.role_admin_for?(seller) || scheduled_by.role_marketing_for?(seller))
    rescue ActiveRecord::RecordNotFound
      false
    end
end
