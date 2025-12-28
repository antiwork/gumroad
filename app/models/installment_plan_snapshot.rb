# frozen_string_literal: true

class InstallmentPlanSnapshot < ApplicationRecord
  include JsonData

  belongs_to :payment_option

  attr_json_data_accessor :offer_code_snapshot

  validates :payment_option, uniqueness: true
  validates :number_of_installments, presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :recurrence, presence: true
  validates :total_price_cents, presence: true, numericality: { greater_than: 0, only_integer: true }

  def has_locked_offer_code?
    offer_code_snapshot.present? &&
      (offer_code_snapshot["amount_cents"].present? || offer_code_snapshot["amount_percentage"].present?)
  end

  def locked_offer_code_id
    offer_code_snapshot&.dig("id")
  end

  def locked_offer_code_code
    offer_code_snapshot&.dig("code")
  end

  def locked_discount_amount_cents
    offer_code_snapshot&.dig("amount_cents")
  end

  def locked_discount_percentage
    offer_code_snapshot&.dig("amount_percentage")
  end

  def locked_offer_code_is_percent?
    offer_code_snapshot&.dig("is_percent") || false
  end

  def locked_offer_code_duration_in_months
    offer_code_snapshot&.dig("duration_in_months")
  end

  def locked_offer_code_currency
    offer_code_snapshot&.dig("currency_type")
  end

  def locked_discount_amount_off(price_cents)
    return 0 if !has_locked_offer_code?

    if locked_offer_code_is_percent?
      (price_cents * (locked_discount_percentage / 100.0)).round
    else
      locked_discount_amount_cents || 0
    end
  end

  def snapshot_offer_code!(offer_code)
    return if offer_code.nil?

    self.offer_code_snapshot = {
      "id" => offer_code.id,
      "code" => offer_code.code,
      "amount_cents" => offer_code.amount_cents,
      "amount_percentage" => offer_code.amount_percentage,
      "is_percent" => offer_code.is_percent?,
      "duration_in_months" => offer_code.duration_in_months,
      "currency_type" => offer_code.currency_type
    }
  end

  def calculate_installment_payment_price_cents
    base_price = total_price_cents / number_of_installments
    remainder = total_price_cents % number_of_installments

    Array.new(number_of_installments) do |i|
      i.zero? ? base_price + remainder : base_price
    end
  end
end
