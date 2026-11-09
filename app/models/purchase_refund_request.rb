# frozen_string_literal: true

# A buyer's request for a refund. It moves no money: the seller refunds from the sale page,
# and support takes over if the purchase is still unrefunded after the deadline. The status
# comes from the purchase itself, so a refund or dispute needs no sync back to this row.
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

  validates :email, presence: true
  validates :message, length: { maximum: MAX_MESSAGE_LENGTH }

  after_create_commit :notify_seller_and_buyer

  # Unresolved requests only: refunded and disputed ones never escalate. The deadline is at least
  # ESCALATION_BUSINESS_DAYS after creation, so the created_at bound is a superset.
  scope :escalation_candidates, -> {
    where(escalated_at: nil, created_at: ..ESCALATION_BUSINESS_DAYS.days.ago)
      .joins(:purchase).merge(Purchase.not_fully_refunded).merge(Purchase.not_chargedback)
  }

  # A dispute closes the request even if the seller later wins it: the buyer went to the bank.
  def status
    return "refunded" if purchase.refunded?
    return "disputed" if purchase.chargedback?

    escalated_at? ? "escalated" : "requested"
  end

  def escalation_due? = status == "requested" && escalation_deadline.past?

  def escalation_deadline = self.class.escalation_deadline_from(created_at)

  # Support's email goes first: if it fails, escalated_at stays unset and the next run retries.
  def escalate!
    mail = SupportContactMailer.contact_form(email:, category: SUPPORT_CATEGORY, message: support_message).deliver_now
    # RescueSmtpErrors returns a rejected send instead of raising it.
    raise mail if mail.is_a?(Exception)

    update!(escalated_at: Time.current)
    log_event("escalated")
    CustomerLowPriorityMailer.refund_request_escalated(id).deliver_later(queue: "default")
  end

  def self.escalation_deadline_from(time)
    deadline = time.to_date
    ESCALATION_BUSINESS_DAYS.times do
      deadline += 1
      deadline += 1 while deadline.saturday? || deadline.sunday?
    end
    deadline.end_of_day
  end

  def self.purchase_eligible?(purchase) = ineligibility(purchase).nil?

  def self.ineligibility(purchase)
    # Not preorder authorizations: the card is only held, so there is nothing to refund.
    return "not_charged" if !purchase.successful? || purchase.price_cents.to_i <= 0
    return "refunded" if purchase.refunded?
    return "disputed" if purchase.chargedback?
    return "partially_refunded" if purchase.stripe_partially_refunded?

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

  # Renewals, plan changes and released preorder charges get no policy row of their own;
  # the checkout (or preorder authorization) purchase has it.
  def self.refund_period_in_days(purchase)
    policy = purchase.purchase_refund_policy ||
      purchase.subscription&.true_original_purchase&.purchase_refund_policy ||
      purchase.preorder&.authorization_purchase&.purchase_refund_policy
    policy&.max_refund_period_in_days
  end

  def self.page_link(purchase)
    Rails.application.routes.url_helpers.purchase_refund_request_url(
      purchase.secure_external_id(scope: SECURE_ID_SCOPE, expires_at: LINK_EXPIRY.from_now),
      host: UrlService.domain_with_protocol
    )
  end

  private
    def notify_seller_and_buyer
      log_event("created")
      ContactingCreatorMailer.refund_requested(id).deliver_later(queue: "default")
      CustomerLowPriorityMailer.refund_request_received(id).deliver_later(queue: "default")
    end

    def support_message
      <<~MESSAGE
        Buyer refund request ##{id} is still unrefunded after #{ESCALATION_BUSINESS_DAYS} business days. Needs action.

        Purchase: #{purchase.external_id}
        Product: #{purchase.link.name}
        Amount: #{purchase.formatted_display_price}
        Reason: #{REASON_LABELS[reason]}
        Refunded so far: #{purchase.stripe_partially_refunded? ? "partially" : "nothing"}
        Message: #{message.presence || "(none)"}
      MESSAGE
    end

    # Never log the free-text message.
    def log_event(event)
      Rails.logger.info("[PurchaseRefundRequest] id=#{id} purchase_id=#{purchase_id} event=#{event} reason=#{reason}")
    end
end
