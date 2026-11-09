# frozen_string_literal: true

class PurchaseRefundRequest < ApplicationRecord
  belongs_to :purchase

  MAX_MESSAGE_LENGTH = 2_000
  SECURE_ID_SCOPE = "refund_request"
  # The link is the buyer's only way back to the status page, so it outlives any refund window.
  LINK_EXPIRY = 6.months
  DATE_FORMAT = "%A, %B %-d"
  SUPPORT_CATEGORY = "purchases & refunds"
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

  STATES = %w[requested refunded expired escalated].freeze
  OPEN_STATES = %w[requested].freeze
  # Refunded needs no entry: ineligibility already rejects refunded purchases.
  TERMINAL_BLOCKING_STATES = %w[expired escalated].freeze
  # Still awaiting an outcome: a later refund or chargeback closes these, and owed
  # notifications are still sent (escalation closes the buyer form, not the seller's email).
  RESOLVABLE_STATES = (OPEN_STATES + %w[escalated]).freeze
  enum :state, STATES.index_by(&:itself), prefix: true, validate: true

  validates :email, presence: true
  validates :message, length: { maximum: MAX_MESSAGE_LENGTH }

  before_save :sync_open_key
  after_create :log_event
  after_update :log_event, if: :saved_change_to_state?
  after_create_commit :enqueue_notifications

  scope :open_state, -> { where(state: OPEN_STATES) }

  def self.open_for(purchase)
    open_state.find_by(purchase_id: purchase.id)
  end

  def open? = OPEN_STATES.include?(state)

  def awaiting_outcome? = RESOLVABLE_STATES.include?(state)

  # Past the deadline the escalation email is support's notice, so no support copy is owed.
  def notifications_pending?
    awaiting_outcome? &&
      (seller_notified_at.nil? || buyer_notice_owed? || (support_notified_at.nil? && !escalation_deadline.past?))
  end

  # Past the deadline the confirmation would quote a date already gone; the escalation notice replaces it.
  def buyer_notice_owed?
    (open? && buyer_notified_at.nil? && !escalation_deadline.past?) ||
      (state_escalated? && buyer_escalation_notified_at.nil?)
  end

  def enqueue_notifications
    PurchaseRefundRequests::NotifyJob.perform_async(id)
  end

  # Backstop for a missed refund/chargeback sync: close the request from the purchase's own
  # state. Returns true when the purchase is resolved, so callers send nothing.
  def close_if_purchase_resolved!
    resolved_state = if purchase.stripe_refunded?
      "refunded"
    elsif purchase.chargedback?
      "expired"
    end
    return false if resolved_state.nil?

    with_lock { update!(state: resolved_state) if awaiting_outcome? }
    true
  end

  def escalation_deadline = self.class.escalation_deadline_from(created_at)

  def self.escalation_deadline_from(time)
    deadline = time.to_date
    ESCALATION_BUSINESS_DAYS.times do
      deadline += 1
      deadline += 1 while deadline.saturday? || deadline.sunday?
    end
    deadline.end_of_day
  end

  def self.purchase_eligible?(purchase) = ineligibility(purchase).nil?

  # Why the buyer can't request a refund, or nil when they can.
  def self.ineligibility(purchase)
    # Not preorder authorizations: the card is only held, so there is nothing to refund.
    return "not_charged" if !purchase.successful? || purchase.price_cents.to_i <= 0
    return "refunded" if purchase.refunded?
    # Before the partial refund: a dispute is what closed the buyer's request, and the page says so.
    return "chargedback" if purchase.chargedback?
    return "partially_refunded" if purchase.stripe_partially_refunded?
    return "previous_request_closed" if where(purchase_id: purchase.id, state: TERMINAL_BLOCKING_STATES).exists?

    max_days = refund_period_in_days(purchase)
    # 0 = seller sells "no refunds"; the form would promise what they never offered.
    return "no_refunds" if max_days && max_days <= 0
    return "outside_window" if max_days && purchase.created_at <= max_days.days.ago

    nil
  end

  def self.refund_window_end(purchase)
    max_days = refund_period_in_days(purchase)
    purchase.created_at + max_days.days if max_days&.positive?
  end

  # Renewals and plan changes get no policy row of their own; the checkout purchase has it.
  def self.refund_period_in_days(purchase)
    policy = purchase.purchase_refund_policy || purchase.subscription&.true_original_purchase&.purchase_refund_policy
    policy&.max_refund_period_in_days
  end

  def self.page_link(purchase)
    Rails.application.routes.url_helpers.purchase_refund_request_url(
      purchase.secure_external_id(scope: SECURE_ID_SCOPE, expires_at: LINK_EXPIRY.from_now),
      host: UrlService.domain_with_protocol
    )
  end

  private
    def sync_open_key
      # MySQL has no partial unique indexes; open_key carries purchase_id while
      # open and NULL once closed, so the unique index only bites open rows.
      self.open_key = open? ? purchase_id : nil
    end

    # Never log the free-text message.
    def log_event
      Rails.logger.info(
        "[PurchaseRefundRequest] id=#{id} purchase_id=#{purchase_id} state=#{state} reason=#{reason}"
      )
    end
end
