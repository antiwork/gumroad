# frozen_string_literal: true

class FrozenInstallmentConfig
  attr_reader :number_of_installments, :recurrence

  def initialize(number_of_installments:, recurrence:)
    @number_of_installments = number_of_installments
    @recurrence = recurrence
  end

  def calculate_installment_payments(full_price_cents)
    base_price = full_price_cents / number_of_installments
    remainder = full_price_cents % number_of_installments

    Array.new(number_of_installments) do |i|
      i.zero? ? base_price + remainder : base_price
    end
  end
end
