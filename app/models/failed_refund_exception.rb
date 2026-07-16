# frozen_string_literal: true

# Durable work item for a refund that failed after Stripe accepted it. The owner,
# notification room, and due date snapshot the routing policy in effect when the
# exception was created, so later policy changes do not rewrite its audit history.
class FailedRefundException < ApplicationRecord
  DEFAULT_OWNER = "payments"
  DEFAULT_RESPONSE_SLA_HOURS = 24
  # Ceiling on notification delivery failures. Without it an exception whose email
  # keeps failing would be re-enqueued by the dispatcher every minute forever; once
  # the cap is hit the dispatcher escalates the exception instead, so a broken
  # mailer surfaces as an escalation rather than an invisible retry loop.
  MAX_NOTIFICATION_FAILURES = 20
  STATES = %w[pending escalated resolved].freeze

  belongs_to :refund

  validates :refund_id, uniqueness: true
  validates :owner, :notification_room, :state, :due_at, presence: true
  validates :notification_room, inclusion: { in: CHAT_ROOMS.keys.map(&:to_s) }
  validates :state, inclusion: { in: STATES }

  scope :notification_pending, -> { where(state: "pending", notification_sent_at: nil) }
  scope :notification_deliverable, -> { notification_pending.where(notification_failures: ...MAX_NOTIFICATION_FAILURES) }
  scope :delivery_exhausted, -> { notification_pending.where(notification_failures: MAX_NOTIFICATION_FAILURES..) }
  scope :overdue, -> { where(state: "pending").where(due_at: ..Time.current) }
  scope :unresolved, -> { where.not(state: "resolved") }

  def self.default_owner
    GlobalConfig.get("FAILED_REFUND_EXCEPTION_OWNER", DEFAULT_OWNER)
  end

  def self.response_sla
    GlobalConfig.get("FAILED_REFUND_EXCEPTION_RESPONSE_SLA_HOURS", DEFAULT_RESPONSE_SLA_HOURS).to_i.hours
  end

  def self.default_notification_room(owner:)
    room = GlobalConfig.get("FAILED_REFUND_EXCEPTION_NOTIFICATION_ROOM", owner)
    return room if CHAT_ROOMS.key?(room.to_s.to_sym)

    raise ArgumentError, "Unknown failed-refund notification room: #{room.inspect}"
  end

  def resolve!(resolution:)
    update!(state: "resolved", resolution:, resolved_at: Time.current)
  end

  def escalate!(resolution:)
    update!(state: "escalated", resolution:)
  end
end
