# frozen_string_literal: true

class ChargePresentment < ApplicationRecord
  belongs_to :charge
  has_many :purchase_presentments, dependent: :destroy

  validates :processor, :presentment_currency, :stripe_fx_quote_id, :stripe_fx_quote_expires_at, :fx_rate, presence: true
  validates :presentment_total_cents, :presentment_gumroad_amount_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }
end
