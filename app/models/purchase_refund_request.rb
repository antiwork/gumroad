# frozen_string_literal: true

# A buyer-initiated request to have a purchase refunded. No money moves here:
# the request only notifies the seller (and support) so one of them can issue
# the refund through the existing refund action before the buyer goes to their
# bank. Named PurchaseRefundRequest to match the repo's other purchase-scoped
# records (PurchaseRefundPolicy, PurchaseCustomField, ...).
class PurchaseRefundRequest < ApplicationRecord
  belongs_to :purchase

  MAX_MESSAGE_LENGTH = 2_000

  REASONS = %w[not_received not_as_described no_longer_needed duplicate_purchase other].freeze
  REASON_LABELS = {
    "not_received" => "I never received the product",
    "not_as_described" => "The product wasn't as described",
    "no_longer_needed" => "I no longer need it",
    "duplicate_purchase" => "I was charged twice for the same purchase",
    "other" => "Something else",
  }.freeze

  enum :reason, REASONS.index_by(&:itself), prefix: true, validate: true

  # requested -> seen (seller opened it) -> refunded / declined; expired is for
  # requests nobody acted on. Open states keep `open_key` = purchase_id so the
  # unique index enforces one open request per purchase (MySQL has no partial
  # unique indexes); closing a request nulls the key.
  STATES = %w[requested seen refunded declined expired].freeze
  OPEN_STATES = %w[requested seen].freeze
  enum :state, STATES.index_by(&:itself), prefix: true, validate: true

  validates :email, presence: true
  validates :message, length: { maximum: MAX_MESSAGE_LENGTH }

  before_save :sync_open_key
  after_create :log_event
  after_update :log_event, if: :saved_change_to_state?

  scope :open_state, -> { where(state: OPEN_STATES) }

  def self.open_for(purchase)
    open_state.find_by(purchase_id: purchase.id)
  end

  def open? = OPEN_STATES.include?(state)

  # A purchase qualifies for a request only while a refund is still the cheaper
  # outcome: it was actually charged, hasn't already been refunded or charged
  # back, and the seller's refund window (when the purchase recorded one) hasn't
  # lapsed. A purchase with no recorded policy window is allowed: the whole
  # point is catching the buyer before the bank does, and support can still
  # decline.
  def self.purchase_eligible?(purchase)
    return false unless purchase.purchase_state.in?(Purchase::CHARGED_SUCCESS_STATES)
    return false if purchase.price_cents.to_i <= 0
    return false if purchase.refunded? || purchase.stripe_partially_refunded?
    return false if purchase.chargedback?

    max_days = purchase.purchase_refund_policy&.max_refund_period_in_days
    # 0 means the seller sells "no refunds" — the request form would promise
    # something the seller never offered, so route those buyers to support.
    return false if max_days && max_days <= 0
    return false if max_days && purchase.created_at <= max_days.days.ago

    true
  end

  private
    def sync_open_key
      self.open_key = open? ? purchase_id : nil
    end

    # One stable prefix so request->refund conversion is countable in SQL over
    # the logs (and the row's own state/timestamps carry the same facts).
    def log_event
      Rails.logger.info(
        "[PurchaseRefundRequest] id=#{id} purchase_id=#{purchase_id} state=#{state} reason=#{reason}"
      )
    end
end
