# frozen_string_literal: true

# Handles moving money for the Gumroad main Stripe account.
# Provides information about how much money is in the Stripe
# balance, and functionality to move money from the Stripe balance
# to Gumroad's bank account.
module StripeTransferExternallyToGumroad
  # Maximum amount Stripe is able to transfer in a single transfer.
  MAX_TRANSFER_AMOUNT = 99_999_999_99
  private_constant :MAX_TRANSFER_AMOUNT

  # Public: Returns a hash of currencies to balance amounts in cents
  # of the balances available at Stripe on our master account.
  # The balances returned are only the balance available for transfer.
  def self.available_balances
    balance = Stripe::Balance.retrieve
    available_balances = {}
    balance.available.each do |balance_for_currency|
      currency = balance_for_currency["currency"]
      amount_cents = balance_for_currency["amount"]
      available_balances[currency] = amount_cents
    end
    available_balances
  end

  # Public: Transfers the amount from the Stripe master account to
  # the default bank account for the given currency.
  def self.transfer(currency, amount_cents)
    description = "#{currency.upcase} #{Time.current.strftime('%y%m%d %H%M')}"
    Stripe::Payout.create(
      amount: amount_cents,
      currency:,
      description:,
      statement_descriptor: description
    )
  end

  # Public: Transfers the outstanding available balance in the Stripe
  # master account to the default bank account.
  #
  # buffer_cents – an amount that will be kept in the balance and will
  # not be transfered.
  def self.transfer_all_available_balances(buffer_cents: 0)
    available_balances.map do |currency, balance_cents|
      transfer_amount_cents = [balance_cents - buffer_cents, MAX_TRANSFER_AMOUNT].min
      next if transfer_amount_cents <= 0

      transfer(currency, transfer_amount_cents)
    end
  end
end
