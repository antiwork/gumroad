# frozen_string_literal: true

module PayoutEstimates
  def self.estimate_held_amount_cents(date, processor_type)
    payment_estimates = estimate_payments_for_balances_up_to_date_for_users(date, processor_type, User.holding_balance)
    holder_of_funds_amount_cents = Hash.new(0)
    payment_estimates.each do |payment_estimate|
      payment_estimate[:holder_of_funds_amount_cents].each do |holder_of_funds, amount_cents|
        holder_of_funds_amount_cents[holder_of_funds] += amount_cents
      end
    end

    holder_of_funds_amount_cents
  end

  def self.estimate_payments_for_balances_up_to_date_for_users(date, processor_type, users)
    payment_estimates = []
    users.each do |user|
      next unless Payouts.is_user_payable(user, date, processor_type:)

      balances = get_balances(date, processor_type, user)
      balance_cents = balances.sum(&:amount_cents)
      payment_estimates << {
        user:,
        amount_cents: balance_cents,
        holder_of_funds_amount_cents: balances.each_with_object(Hash.new(0)) do |balance, hash|
          hash[balance.merchant_account.holder_of_funds] += balance.amount_cents
        end
      }
    end
    payment_estimates
  end

  private_class_method
  def self.get_balances(date, processor_type, user)
    user.unpaid_balances_up_to_date(date).select do |balance|
      ::PayoutProcessorType.get(processor_type).is_balance_payable(balance)
    end
  end
end
