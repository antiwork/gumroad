# frozen_string_literal: true

module PayoutEstimates
  # Fast set-based estimate of the unpaid balance that will be transferred out
  # of Gumroad's Stripe platform balance for payouts up to a date. Gumroad-held
  # Stripe balances live on the platform merchant accounts (user_id IS NULL).
  #
  # Mirrors the payout cycle's per-user gates in SQL instead of the per-user
  # loop in estimate_held_amount_cents: only compliant users whose payouts are
  # not paused, who are paid out via Stripe (an alive bank account, rather
  # than PayPal which is funded from Gumroad's PayPal account), and whose
  # summed balance meets the global minimum payout amount. Per-user payout
  # thresholds above the global minimum and payments already made for the
  # same period are not modelled, so the estimate errs slightly on the high
  # side -- the safe direction for "is the balance high enough?".
  def self.estimate_gumroad_held_stripe_cents(date)
    merchant_account_ids = MerchantAccount.where(
      user_id: nil,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    ).ids

    Balance.unpaid
           .where(merchant_account_id: merchant_account_ids)
           .where("balances.date <= ?", date)
           .joins(:user)
           .merge(User.compliant)
           .where(User.not_payouts_paused_internally_condition)
           .where(User.not_payouts_paused_by_user_condition)
           .where(BankAccount.alive.where("bank_accounts.user_id = balances.user_id").arel.exists)
           .group(:user_id)
           .having("SUM(balances.amount_cents) >= ?", Payouts::MIN_AMOUNT_CENTS)
           .sum(:amount_cents)
           .values
           .sum
  end

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
