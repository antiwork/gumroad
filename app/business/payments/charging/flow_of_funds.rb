# frozen_string_literal: true

class FlowOfFunds
  class Amount
    attr_accessor :currency, :cents

    def initialize(currency:, cents:)
      @currency = currency
      @cents = cents
    end

    def to_h
      {
        currenty: currency,
        cents:
      }
    end
  end

  attr_accessor :issued_amount, :settled_amount, :gumroad_amount, :merchant_account_gross_amount, :merchant_account_net_amount

  # Public: Initialize a new FlowOfFunds with an amount describing the funds at each point in
  # the flow of funds.
  #  - issued_amount - a FlowOfFunds::Amount object describing the amount at the issuer either being charged, refunded, etc
  #  - settled_amount - a FlowOfFunds::Amount object describing the amount at the time of settlement
  #  - gumroad_amount - a FlowOfFunds::Amount object describing the amount at the time of Gumroad collecting the portion it holds
  #  - merchant_account_gross_amount - a FlowOfFunds::Amount object describing the amount at the time of a merchant account collected in whole
  #  - merchant_account_net_amount - a FlowOfFunds::Amount object describing the amount at the time of a merchant account collected minus the gumroad_amount
  def initialize(issued_amount:, settled_amount:, gumroad_amount:, merchant_account_gross_amount: nil, merchant_account_net_amount: nil)
    @issued_amount = issued_amount
    @settled_amount = settled_amount
    @gumroad_amount = gumroad_amount
    @merchant_account_gross_amount = merchant_account_gross_amount
    @merchant_account_net_amount = merchant_account_net_amount
  end

  # Public: Builds a simple FlowOfFunds where the issued, settled and gumroad amounts are the currency
  # and amount_cents given.
  #  - currency - The currency of the amount
  #  - amount_cents - The cents of the amounts
  # Returns a FlowOfFunds.
  def self.build_simple_flow_of_funds(currency, amount_cents)
    amount = Amount.new(currency:, cents: amount_cents)
    FlowOfFunds.new(
      issued_amount: amount,
      settled_amount: amount,
      gumroad_amount: amount
    )
  end

  def to_h
    {
      issued_amount: issued_amount.to_h,
      settled_amount: settled_amount.to_h,
      gumroad_amount: gumroad_amount.to_h,
      merchant_account_gross_amount: merchant_account_gross_amount.to_h,
      merchant_account_net_amount: merchant_account_net_amount.to_h
    }
  end
end
