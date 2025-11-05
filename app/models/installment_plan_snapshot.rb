# frozen_string_literal: true

class InstallmentPlanSnapshot < ApplicationRecord
  belongs_to :payment_option

  validates :payment_option, uniqueness: true
  validates :number_of_installments, presence: true, numericality: { greater_than: 0, only_integer: true }
  validates :recurrence, presence: true
  validates :total_price_cents, presence: true, numericality: { greater_than: 0, only_integer: true }

  def calculate_installment_payment_price_cents
    base_price = total_price_cents / number_of_installments
    remainder = total_price_cents % number_of_installments

    Array.new(number_of_installments) do |i|
      i.zero? ? base_price + remainder : base_price
    end
  end
end
