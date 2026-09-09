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
  before_save :sync_fee_retention_recoverable
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
  attr_json_data_accessor :retained_fee_cents
  attr_json_data_accessor :fee_retention_pending
  attr_json_data_accessor :fee_retention_error
  attr_json_data_accessor :fee_retention_collected_cents
  attr_json_data_accessor :fee_retention_source_transfer
  attr_json_data_accessor :fee_retention_attempts

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

  FEE_RETENTION_ERRORS = [Stripe::InvalidRequestError, Stripe::APIError, Stripe::APIConnectionError,
                          Stripe::AuthenticationError, Stripe::PermissionError, Stripe::RateLimitError,
                          Stripe::IdempotencyError].freeze

  # One week of hourly RecoverPendingRefundFeeRetentionJob runs: a Stripe-held account
  # with no reversible transfer yet receives its next payout transfer inside this window.
  # At the cap the row stays fee_retention_pending for visibility but leaves the job's
  # candidate set (fee_retention_recoverable).
  MAX_FEE_RETENTION_ATTEMPTS = 168

  scope :pending_fee_retention, -> { where(fee_retention_recoverable: true) }

  def retain_fee
    yield
  rescue *FEE_RETENTION_ERRORS => error
    record_fee_retention_failure!(error)
    nil
  end

  def record_fee_retention_failure!(error)
    self.fee_retention_pending = true
    self.fee_retention_error = { class: error.class.name, message: error.message }
    save!
    ErrorNotifier.notify(error, context: { refund_id: id, purchase_id: purchase_id })
  end

  def recover_pending_fee_retention!
    pending = purchase.with_lock { reload.fee_retention_pending }
    return unless pending

    credit = Credit.find_by(fee_retention_refund: self, failed_refund_id: nil)
    unless credit
      message = "Pending refund fee retention has no Credit"
      Rails.logger.error("#{message} (refund_id=#{id})")
      ErrorNotifier.notify(message, context: { refund_id: id, purchase_id: purchase_id })
      return
    end

    # Gate on terminally_failed?, not effective?: Stripe-held failures are never
    # balance-reversed, so effective? stays true and would collect a fee for a refund
    # the buyer never received. Existing pins and grouped debits are still adopted.
    credit.fee_retention_refund = self
    lookup_failed = false
    retain_fee do
      StripeChargeProcessor.debit_stripe_account_for_refund_fee(credit:, collect: !terminally_failed?)
    rescue *FEE_RETENTION_ERRORS
      lookup_failed = true
      raise
    end

    attempts_exhausted = false
    purchase.with_lock do
      reload.lock!
      next unless fee_retention_pending
      collection_recorded = debited_stripe_transfer.present? && fee_retention_collected_cents.present?
      no_stripe_collection = credit.amount_cents.zero? || credit.merchant_account.holder_of_funds != HolderOfFunds::STRIPE
      terminal_without_collection = terminally_failed? && debited_stripe_transfer.blank? && !lookup_failed
      unless collection_recorded || no_stripe_collection || terminal_without_collection
        attempts_exhausted = record_fee_retention_attempt!
        next
      end

      if fee_retention_collected_cents.present?
        holding_cents = BalanceTransaction.where(credit:).sum(:holding_amount_net_cents)
        adjustment_cents = -fee_retention_collected_cents - holding_cents
        unless adjustment_cents.zero?
          BalanceTransaction.create!(user: credit.user, merchant_account: credit.merchant_account, credit:,
                                     issued_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 0, net_cents: 0),
                                     holding_amount: BalanceTransaction::Amount.new(currency: credit.merchant_account.currency,
                                                                                    gross_cents: adjustment_cents, net_cents: adjustment_cents))
        end
      end
      self.fee_retention_pending = false
      self.fee_retention_error = nil
      save!
    end
    return unless attempts_exhausted

    message = "Refund fee retention stopped retrying after #{MAX_FEE_RETENTION_ATTEMPTS} attempts"
    Rails.logger.error("#{message} (refund_id=#{id})")
    ErrorNotifier.notify(message, context: { refund_id: id, purchase_id:, fee_retention_error: })
  end

  def fee_retention_attempts_exhausted?
    fee_retention_attempts.to_i >= MAX_FEE_RETENTION_ATTEMPTS
  end

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
    def sync_fee_retention_recoverable
      self.fee_retention_recoverable = fee_retention_pending == true && !fee_retention_attempts_exhausted?
    end

    # True only on the attempt that reaches the cap, so the caller reports it once.
    def record_fee_retention_attempt!
      self.fee_retention_attempts = fee_retention_attempts.to_i + 1
      save!
      fee_retention_attempts == MAX_FEE_RETENTION_ATTEMPTS
    end

    def assign_product
      self.link_id = purchase.link_id
    end

    def assign_seller
      self.seller_id = purchase.seller_id
    end
end
