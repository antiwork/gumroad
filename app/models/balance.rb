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
  # holding_currency = The currency the balance is being held in.
  # Different if the funds were charged in USD, then settled and held in a merchant account in CAD, AUD, etc.
  validates :merchant_account, :currency, :holding_currency, presence: true
  validate :validate_amounts_are_only_changed_when_unpaid, on: :update

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

    def log_transition
      logger.info "Balance: balance ID #{id} transitioned to #{state}"
    end
end
