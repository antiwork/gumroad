# frozen_string_literal: true

# This class represents a point-in-time snapshot of an installment plan configuration.
# We needed this because customers were getting charged different amounts when sellers
# changed their product settings after the customer had already subscribed.
#
# The Problem We're Solving:
# - Customer buys a $147 product with 3 monthly installments ($49 each)
# - Seller later changes the product to $197 with 2 installments
# - Without this fix, the customer's remaining payments would change to $98.50 each
# - That's wrong - the customer agreed to pay $147 in 3 installments, not $197 in 2
#
# This class stores the original installment configuration (how many payments, how often)
# so we can always calculate the correct billing amounts based on what the customer
# originally agreed to, not what the seller changed it to later.
#
class FrozenInstallmentConfig
  attr_reader :number_of_installments, :recurrence

  def initialize(number_of_installments:, recurrence:)
    # Store the installment count (e.g., 3 payments)
    @number_of_installments = number_of_installments

    # Store the payment frequency (e.g., "monthly")
    @recurrence = recurrence
  end

  # Divides the total price into equal installment payments.
  # Any leftover cents from rounding go into the first payment.
  #
  # Why put the remainder in the first payment?
  # - It's less confusing for customers (first payment slightly higher, rest are equal)
  # - Matches existing ProductInstallmentPlan behavior for consistency
  # - Avoids the last payment being unexpectedly different
  #
  # Example: $100 split into 3 installments
  # - Base amount: $100 / 3 = $33 per payment
  # - Remainder: $100 % 3 = $1 left over
  # - Result: [$34, $33, $33] - first payment gets the extra $1
  #
  def calculate_installment_payments(full_price_cents)
    # Calculate the base payment amount (integer division)
    base_price = full_price_cents / number_of_installments

    # Calculate any remaining cents that don't divide evenly
    remainder = full_price_cents % number_of_installments

    # Build an array with one payment amount per installment
    # The first payment (i == 0) gets the base price plus any remainder
    # All other payments just get the base price
    Array.new(number_of_installments) do |i|
      i.zero? ? base_price + remainder : base_price
    end
  end
end
