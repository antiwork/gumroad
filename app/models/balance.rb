# frozen_string_literal: true

class Balance < ApplicationRecord
  include ExternalId
  include Balance::Searchable
  include Balance::RefundEligibilityUnderwriter

  belongs_to :user, optional: true
  belongs_to :merchant_account, optional: true

  has_many :balance_transactions

  has_many :successful_sales, class_name: "Purchase", foreign_key: :purchase_success_balance_id
  has_many :chargedback_sales, class_name: "Purchase", foreign_key: :purchase_chargeback_balance_id
  has_many :refunded_sales, class_name: "Purchase", foreign_key: :purchase_refund_balance_id

  has_many :successful_affiliate_credits, class_name: "AffiliateCredit", foreign_key: :affiliate_credit_success_balance_id
  has_many :chargedback_affiliate_credits, class_name: "AffiliateCredit", foreign_key: :affiliate_credit_chargeback_balance_id
  has_many :refunded_affiliate_credits, class_name: "AffiliateCredit", foreign_key: :affiliate_credit_refund_balance_id

  has_many :credits
  has_and_belongs_to_many :payments, join_table: "payments_balances"

  # currency = The currency the balance was collected in.
  #
  # holding_currency = The currency the balance is being held in, which means different things
  # depending on who holds the funds:
  #
  #   - A seller's own connected account (merchant_account.holder_of_funds STRIPE or CREATOR):
  #     the currency that account's balance is denominated in. Legitimately non-USD — funds
  #     charged in USD can settle and be held in CAD, AUD, GBP, etc.
  #   - Gumroad-held funds (holder_of_funds GUMROAD): ALWAYS USD. Here holding_currency and
  #     holding_amount_cents are Gumroad's canonical record of what it owes the seller — a
  #     liability — not a statement about which currency Stripe is physically holding. Stripe's
  #     platform account does carry real foreign-currency balances, but that is an account-level
  #     treasury position spanning every seller, and it is not recorded here. Payouts of
  #     Gumroad-held funds are computed and wired in USD, and both StripePayoutProcessor and
  #     PaypalPayoutProcessor reject a Gumroad-held balance whose holding_currency is not USD, so
  #     a foreign currency on one of these rows blocks the seller's money rather than merely
  #     describing it oddly (see gumroad-private#1471).
  #
  # Note that balances are keyed on holding_currency (see find_or_create_balance), so a seller
  # would get parallel same-day balances if this ever varied within a day for one account.
  #
  # On a buyer-presentment charge the buyer's currency is converted at the rate they were quoted,
  # which has Stripe's FX fee priced in rather than being the interbank rate. The buyer pays that
  # spread inside the price they confirmed; this ledger stays exact on both sides, so quoting
  # nearer interbank would be a pricing decision, not a correctness fix (gumroad-private#1318).
  validates :merchant_account, :currency, :holding_currency, presence: true
  validate :validate_amounts_are_only_changed_when_unpaid, on: :update
  # Only when the currency or amount fields change, so a state transition on a row written
  # before this check (the repair backlog) is not refused.
  validate :validate_gumroad_held_amounts_are_usd, if: :currency_or_amounts_changing?

  # Balance state machine
  #
  # unpaid  →  processing  →  paid
  #  ↓  ↑           ↓           ↓
  #  ↓  ↑ ← ← ← ← ← ← ← ← ← ← ← ←
  #  ↓
  # forfeited
  #
  # Note: Amounts are only changeable when in an unpaid state.
  #
  state_machine(:state, initial: :unpaid) do
    event :mark_forfeited do
      transition unpaid: :forfeited
    end

    event :mark_processing do
      transition unpaid: :processing
    end

    event :mark_paid do
      transition processing: :paid
    end

    event :mark_unpaid do
      transition %i[processing paid] => :unpaid
    end

    state any do
      validates_presence_of :amount_cents
    end

    after_transition any => any, :do => :log_transition
  end

  enum :state, %w[unpaid processing paid forfeited].index_by(&:itself), default: "unpaid"

  private
    def validate_amounts_are_only_changed_when_unpaid
      return if unpaid?

      %i[
        amount_cents
        holding_amount_cents
      ].each do |field|
        errors.add(field, "may not be changed in #{state} state.") if field.to_s.in?(changed)
      end
    end

    def currency_or_amounts_changing?
      new_record? || will_save_change_to_currency? || will_save_change_to_holding_currency? ||
        will_save_change_to_amount_cents? || will_save_change_to_holding_amount_cents?
    end

    def validate_gumroad_held_amounts_are_usd
      return unless merchant_account&.holder_of_funds == HolderOfFunds::GUMROAD

      errors.add(:holding_currency, "must be usd for Gumroad-held funds") unless holding_currency == Currency::USD
      return unless currency == Currency::USD && holding_currency == Currency::USD

      errors.add(:holding_amount_cents, "must equal amount_cents for Gumroad-held funds") unless holding_amount_cents == amount_cents
    end

    def log_transition
      logger.info "Balance: balance ID #{id} transitioned to #{state}"
    end
end
