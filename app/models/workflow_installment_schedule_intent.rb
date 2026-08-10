# frozen_string_literal: true

class WorkflowInstallmentScheduleIntent < ApplicationRecord
  class EnqueueError < StandardError; end

  DISPATCH_LEASE = 15.minutes

  scope :pending, -> { where(processed_at: nil) }
  scope :dispatchable, ->(at = Time.current) { pending.where("dispatch_expires_at IS NULL OR dispatch_expires_at <= ?", at) }

  validates :token, :installment_id, :rule_version, :cutoff_reference_time, presence: true

  def self.enqueue!(installment:, rule_version:, old_delayed_delivery_time:, cutoff_reference_time:, expected_published_at: nil)
    raise EnqueueError, "A database transaction is required" unless connection.transaction_open?

    intent = create!(
      token: SecureRandom.uuid,
      installment_id: installment.id,
      rule_version:,
      old_delayed_delivery_time:,
      cutoff_reference_time:,
      expected_published_at:
    )

    token = intent.token
    AfterCommitEverywhere.after_commit { enqueue(token) }

    intent
  end

  def self.enqueue(token)
    dispatch_token = SecureRandom.uuid
    now = Time.current
    claimed = dispatchable(now).where(token:).update_all(
      dispatch_token:,
      dispatch_expires_at: now + DISPATCH_LEASE,
      updated_at: now
    )
    return if claimed.zero?

    job_id = ScheduleWorkflowInstallmentJob.perform_async(token)
    release_dispatch(token:, dispatch_token:) if job_id.blank?
    job_id
  rescue => e
    Rails.logger.error("[#{name}] could not enqueue token=#{token}: #{e.class}: #{e.message}")
    nil
  end

  def self.mark_processed(token)
    return if token.blank?

    now = Time.current
    pending.where(token:).update_all(
      processed_at: now,
      dispatch_token: nil,
      dispatch_expires_at: nil,
      updated_at: now
    )
  end

  def mark_processed!
    update!(processed_at: Time.current, dispatch_token: nil, dispatch_expires_at: nil)
  end

  def self.release_dispatch(token:, dispatch_token:)
    pending.where(token:, dispatch_token:).update_all(
      dispatch_token: nil,
      dispatch_expires_at: nil,
      updated_at: Time.current
    )
  end
  private_class_method :release_dispatch
end
