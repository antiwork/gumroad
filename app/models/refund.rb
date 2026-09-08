# frozen_string_literal: true

class Refund < ApplicationRecord
  FRAUD = "fraud"

  # Stripe refund statuses that mean the buyer did NOT receive the money and never
  # will through this refund. "failed" is a refund the buyer's bank returned after
  # Stripe accepted it; "canceled" is a pending refund that was canceled before it
  # completed (Stripe documents both as terminal and returns the money to the
  # platform balance either way). Both must stop counting as refunded money once
  # their balance debits are reversed — treat them identically everywhere except
  # for the persisted status itself, which keeps Stripe's actual value.
  TERMINAL_FAILURE_STATUSES = %w(failed canceled).freeze

  include JsonData, FlagShihTzu, ExternalId

  belongs_to :user, foreign_key: :refunding_user_id, optional: true
  belongs_to :purchase
  belongs_to :product, class_name: "Link", foreign_key: :link_id
  belongs_to :seller, class_name: "User"
  has_many :balance_transactions
  has_one :credit
  has_one :failed_refund_exception

  before_validation :assign_product, on: :create
  before_validation :assign_seller, on: :create
  validates_uniqueness_of :processor_refund_id, scope: :link_id, allow_blank: true

  # Refund selection for the tax report jobs' refund leg: refunds that get reported as their
  # own negative rows in the period the refund happened. Only refunds created on/after the
  # refund reporting cutover qualify — earlier refunds were (and stay) netted into their
  # purchase's period, so including them here would relieve the same tax twice. Restricted to
  # .effective (the canonical "money actually moved" scope) so a reversed-failure refund — money
  # returned to us, never received by the buyer — never produces a negative row; the same scope
  # backs the pre-cutover netting and the other tax reports, so "which refunds count" has one
  # answer everywhere. See Purchase::Reportable::REFUND_REPORTING_CUTOVER for the cutover contract.
  scope :for_tax_period_reporting, lambda { |starts_at, ends_at|
    effective
      .where(created_at: starts_at..ends_at)
      .where("refunds.created_at >= ?", Purchase::Reportable::REFUND_REPORTING_CUTOVER.beginning_of_day)
  }

  has_flags 1 => :is_for_fraud,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  # Refunds whose money actually left (or is leaving) our account. A refund with a
  # terminal-failure status ("failed" or "canceled" — see TERMINAL_FAILURE_STATUSES)
  # is one the buyer never received the money for, so those rows must not count
  # toward how much of a purchase has been refunded. status is NULL for refunds
  # created before we started persisting processor status, all of which completed,
  # so NULL counts as effective.
  #
  # A terminally-failed refund stops counting only once Purchase::HandleFailedRefundService
  # has actually reversed the balance debits it created (balance_reversed_on_failure).
  # One that was NOT auto-reversed (external funds, dispute, legacy rows)
  # still has the seller debited, so it must keep counting toward the refunded sums —
  # otherwise amount_refundable_cents would look refundable while the purchase's
  # stripe_refunded flag (which only the reversal path recomputes) still blocks the
  # admin refund action.
  scope :effective, -> {
    where(<<~SQL.squish, statuses: TERMINAL_FAILURE_STATUSES)
      refunds.status IS NULL
      OR refunds.status NOT IN (:statuses)
      OR COALESCE(refunds.json_data->>'$.balance_reversed_on_failure', 'false') != 'true'
    SQL
  }

  # The complement of .effective among terminally-failed rows: refunds that failed
  # or were canceled after acceptance AND whose balance debits have been offset by
  # Purchase::HandleFailedRefundService. Payout exports render these as an explicit
  # debit + reversal pair instead of ordinary refund rows.
  scope :reversed_failures, -> {
    where(status: TERMINAL_FAILURE_STATUSES)
      .where("COALESCE(refunds.json_data->>'$.balance_reversed_on_failure', 'false') = 'true'")
  }

  attr_json_data_accessor :note
  attr_json_data_accessor :business_vat_id
  attr_json_data_accessor :debited_stripe_transfer
  # True until Credit.create_for_refund_fee_retention! finishes (or is waived). Survives process
  # death between refund commit and after_commit fee retention.
  attr_json_data_accessor :refund_fee_retention_pending

  # Fee retention still outstanding (set when the refund commits; cleared when retention finishes)
  # or Stripe debit left in pending_retry. Retry jobs revisit these within the idempotency window.
  scope :pending_fee_debit_retry, -> {
    where(
      "refunds.json_data->>'$.debited_stripe_transfer' = ? OR COALESCE(refunds.json_data->>'$.refund_fee_retention_pending', 'false') = 'true'",
      Credit::FEE_DEBIT_PENDING_RETRY
    )
  }

  # Sticky recovery route chosen before the Stripe submit (transfer_reversal / eur_debit /
  # us_debit). Retries must resume this route instead of selecting a new one.
  attr_json_data_accessor :refund_fee_debit_operation
  # Stripe transfer id and amount (in that transfer's currency) for a sticky transfer_reversal.
  attr_json_data_accessor :refund_fee_debit_transfer_id
  attr_json_data_accessor :refund_fee_debit_amount_cents
  # Bumped when a definitive Stripe InvalidRequest clears the sticky choice so the next
  # attempt can use a fresh idempotency key without colliding with the rejected one.
  attr_json_data_accessor :refund_fee_debit_generation
  # EUR cents requested for the BGN-fallback platform debit; reused on retry so the
  # Stripe idempotency key always pairs with the same amount parameters.
  attr_json_data_accessor :refund_fee_eur_debit_cents
  # Holding-currency cents actually taken from Stripe for this fee debit, when known.
  attr_json_data_accessor :refund_fee_holding_debit_cents
  # Currency of refund_fee_holding_debit_cents (merchant account currency at debit time).
  attr_json_data_accessor :refund_fee_holding_debit_currency
  # Holding cents already applied to balances.holding_amount_cents for this fee debit;
  # keeps reconcile_fee_retention_holding_amount! from subtracting the same delta twice.
  attr_json_data_accessor :refund_fee_holding_reconciled_cents
  # UTC time the sticky fee-debit operation was first submitted to Stripe (ISO 8601).
  # Used to refuse automatic resubmits after Stripe's idempotency window.
  attr_json_data_accessor :refund_fee_debit_submitted_at
  attr_json_data_accessor :retained_fee_cents
  attr_json_data_accessor :presentment_currency
  attr_json_data_accessor :presentment_amount_cents
  attr_json_data_accessor :presentment_price_cents
  attr_json_data_accessor :presentment_tip_cents
  attr_json_data_accessor :presentment_seller_tax_cents
  attr_json_data_accessor :presentment_gumroad_tax_cents
  attr_json_data_accessor :presentment_shipping_cents
  # Live-rate settlement facts from the Stripe refund balance transaction. Stripe converts
  # refunds at the live rate (not the locked FX quote rate), so the settled amount differs
  # from the amount originally settled for the charge; the delta against the canonical
  # balance debit is platform-side FX gain or loss. Persisted for treasury reconciliation.
  attr_json_data_accessor :presentment_settled_currency
  attr_json_data_accessor :presentment_settled_amount_cents
  # Set when a refund failed after acceptance (async bank-transfer refunds can be
  # returned by the buyer's bank) and Purchase::HandleFailedRefundService has offset
  # the balance debits this refund created. Guards the reversal against re-delivered
  # refund.failed webhooks.
  attr_json_data_accessor :balance_reversed_on_failure
  # UTC time (ISO 8601 string) at which the balance reversal above was recorded.
  # The finance event ledger books the reversal as its own dated event on this day;
  # the original refund event stays booked to its own day untouched, because ledger
  # days must regenerate bit-identical.
  attr_json_data_accessor :balance_reversed_on_failure_at

  # In-memory mirror of the .effective scope, for callers working with preloaded
  # refunds. Keep the two in sync.
  def effective?
    !TERMINAL_FAILURE_STATUSES.include?(status) || !balance_reversed_on_failure
  end

  def terminally_failed?
    TERMINAL_FAILURE_STATUSES.include?(status)
  end

  # True when this refund carries a buyer-currency (presentment) snapshot. Presentment
  # refunds record the amount actually returned to the buyer in the currency they paid
  # with; refunds created before that feature (or for non-presentment purchases) have
  # neither field and should keep rendering canonical USD amounts only.
  def presentment_snapshot?
    presentment_currency.present? && presentment_amount_cents.to_i > 0
  end

  # The refunded amount in the buyer's own currency, formatted for display
  # (e.g. "CA$28.83"). Nil when there is no presentment snapshot.
  def formatted_presentment_amount
    return nil unless presentment_snapshot?

    MoneyFormatter.format(presentment_amount_cents, presentment_currency.to_sym, no_cents_if_whole: true, symbol: true)
  end

  private
    def assign_product
      self.link_id = purchase.link_id
    end

    def assign_seller
      self.seller_id = purchase.seller_id
    end
end
