# frozen_string_literal: true

class PurchaseRefundRequest < ApplicationRecord
  belongs_to :purchase

  MAX_MESSAGE_LENGTH = 2_000
  # Weekdays only, no holiday calendar — same approximation as PiracyReport.
  ESCALATION_BUSINESS_DAYS = 2

  REASONS = %w[not_received not_as_described no_longer_needed duplicate_purchase other].freeze
  REASON_LABELS = {
    "not_received" => "I never received the product",
    "not_as_described" => "The product wasn't as described",
    "no_longer_needed" => "I no longer need it",
    "duplicate_purchase" => "I was charged twice for the same purchase",
    "other" => "Something else",
  }.freeze

  enum :reason, REASONS.index_by(&:itself), prefix: true, validate: true

  STATES = %w[requested seen refunded declined expired].freeze
  OPEN_STATES = %w[requested seen].freeze
  # declined/expired block a NEW request (anti-harassment); refunded needs no
  # entry here because purchase_eligible? already rejects refunded purchases.
  TERMINAL_BLOCKING_STATES = %w[declined expired].freeze
  enum :state, STATES.index_by(&:itself), prefix: true, validate: true

  validates :email, presence: true
  validates :message, length: { maximum: MAX_MESSAGE_LENGTH }

  before_save :sync_open_key
  after_create :log_event
  after_update :log_event, if: :saved_change_to_state?
  after_create_commit :enqueue_notifications, :schedule_escalation

  scope :open_state, -> { where(state: OPEN_STATES) }

  def self.open_for(purchase)
    open_state.find_by(purchase_id: purchase.id)
  end

  def open? = OPEN_STATES.include?(state)

  # Nil stamps mean a notification is still owed (crash/Redis outage after
  # create); callers may re-enqueue freely — the worker is idempotent on stamps.
  def notifications_pending?
    open? && (seller_notified_at.nil? || support_notified_at.nil?)
  end

  def enqueue_notifications
    PurchaseRefundRequests::NotifyWorker.perform_async(id)
  end

  def escalation_deadline
    deadline = created_at.to_date
    ESCALATION_BUSINESS_DAYS.times do
      deadline += 1
      deadline += 1 while deadline.saturday? || deadline.sunday?
    end
    deadline.end_of_day
  end

  def self.purchase_eligible?(purchase)
    return false unless purchase.purchase_state.in?(Purchase::CHARGED_SUCCESS_STATES)
    return false if purchase.price_cents.to_i <= 0
    return false if purchase.refunded? || purchase.stripe_partially_refunded?
    return false if purchase.chargedback?
    # declined/expired means the seller or the clock already answered; re-asking
    # requires a support action, not a fresh form submit.
    return false if where(purchase_id: purchase.id, state: TERMINAL_BLOCKING_STATES).exists?

    max_days = purchase.purchase_refund_policy&.max_refund_period_in_days
    # 0 = seller sells "no refunds"; the form would promise what they never offered.
    return false if max_days && max_days <= 0
    return false if max_days && purchase.created_at <= max_days.days.ago

    true
  end

  private
    def sync_open_key
      # MySQL has no partial unique indexes; open_key carries purchase_id while
      # open and NULL once closed, so the unique index only bites open rows.
      self.open_key = open? ? purchase_id : nil
    end

    def schedule_escalation
      PurchaseRefundRequests::EscalateWorker.perform_at(escalation_deadline, id)
    end

    # Stable prefix for SQL-countable conversion; never the free-text message.
    def log_event
      Rails.logger.info(
        "[PurchaseRefundRequest] id=#{id} purchase_id=#{purchase_id} state=#{state} reason=#{reason}"
      )
    end
end
