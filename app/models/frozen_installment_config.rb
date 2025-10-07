# frozen_string_literal: true

# Value object representing immutable installment plan configuration.
# Used to ensure billing amounts don't change when product config changes.
#
# When a customer purchases a product with installment payments, we snapshot
# the installment plan configuration (number of installments and recurrence)
# at purchase time. This frozen config is then used for all subsequent
# recurring charges, regardless of any changes the seller makes to the
# product's installment plan.
#
# Example:
#   config = FrozenInstallmentConfig.new(number_of_installments: 3, recurrence: 'monthly')
#   payments = config.calculate_installment_payments(1000) # => [334, 333, 333]
#
class FrozenInstallmentConfig
  attr_reader :number_of_installments, :recurrence

  def initialize(number_of_installments:, recurrence:)
    @number_of_installments = number_of_installments
    @recurrence = recurrence
  end

  # Calculate installment payment amounts for a given total price.
  # Puts any remainder in the first installment to avoid rounding issues.
  #
  # @param full_price_cents [Integer] Total price in cents
  # @return [Array<Integer>] Array of payment amounts in cents, one per installment
  #
  # Example:
  #   config.calculate_installment_payments(1000) # 3 installments
  #   # => [334, 333, 333] (remainder of 1 cent goes to first payment)
  #
  def calculate_installment_payments(full_price_cents)
    base_price = full_price_cents / number_of_installments
    remainder = full_price_cents % number_of_installments

    Array.new(number_of_installments) do |i|
      i.zero? ? base_price + remainder : base_price
    end
  end
end
