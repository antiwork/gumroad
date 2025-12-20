# frozen_string_literal: true

class BalanceTopUp < ApplicationRecord
  include ExternalId
  include CurrencyHelper

  STATES = %w[pending processing successful failed].freeze

  belongs_to :user
  belongs_to :credit_card
  belongs_to :purchase, optional: true
  belongs_to :credit, optional: true

  validates :amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :processor, presence: true

  scope :pending, -> { where(state: "pending") }
  scope :processing, -> { where(state: "processing") }
  scope :successful, -> { where(state: "successful") }
  scope :failed, -> { where(state: "failed") }

  state_machine :state, initial: :pending do
    event :mark_processing do
      transition pending: :processing
    end

    event :mark_successful do
      transition processing: :successful
    end

    event :mark_failed do
      transition %i[pending processing] => :failed
    end
  end

  def formatted_amount
    MoneyFormatter.format(amount_cents, :usd, no_cents_if_whole: true, symbol: true)
  end

  def successful?
    state == "successful"
  end

  def failed?
    state == "failed"
  end

  def pending?
    state == "pending"
  end

  def processing?
    state == "processing"
  end
end
