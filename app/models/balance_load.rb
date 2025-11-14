# frozen_string_literal: true

class BalanceLoad < ApplicationRecord
  include ExternalId

  belongs_to :user
  belongs_to :balance_load_credit_card
  belongs_to :refund, optional: true

  validates :amount_cents, presence: true, numericality: { greater_than_or_equal_to: 100 } # $1 minimum
  validates :currency, presence: true
  validates :state, presence: true

  # State machine: pending → successful/failed
  state_machine :state, initial: :pending do
    event :mark_successful do
      transition pending: :successful
    end

    event :mark_failed do
      transition pending: :failed
    end

    after_transition pending: :successful, do: :credit_user_balance
    after_transition pending: :failed, do: :log_failure
  end

  enum :state, %w[pending successful failed].index_by(&:itself), default: "pending"

  scope :for_user, ->(user_id) { where(user_id:) }
  scope :recent, -> { order(created_at: :desc) }
  scope :successful, -> { where(state: "successful") }
  scope :pending, -> { where(state: "pending") }

  def amount_dollars
    (amount_cents / 100.0).round(2)
  end

  def succeeded?
    state == "successful"
  end

  def failed?
    state == "failed"
  end

  def pending?
    state == "pending"
  end

  private

  def credit_user_balance
    # Add funds to user's unpaid balance via Credit record
    Credit.create!(
      user:,
      merchant_account: user.merchant_account,
      amount_cents:,
      currency:,
      balance_load_id: id,
      note: "Balance loaded via credit card#{refund ? " for refund #{refund.external_id}" : ""}"
    )
  rescue => e
    Rails.logger.error("BalanceLoad #{id}: Failed to credit user balance: #{e.message}")
    # Don't raise - balance load was successful, credit creation can be retried
  end

  def log_failure
    Rails.logger.error("BalanceLoad #{id} failed: #{error_message}")
  end
end
