# frozen_string_literal: true

class StripeChargeRefund < ChargeRefund
  # Public: Create a ChargeRefund from a Stripe::Refund
  #
  # Inherits attr_accessor :charge_processor_id, :id, :charge_id, :flow_of_funds, :refund from ChargeRefund
  attr_reader :charge,
              :destination_payment_refund,
              :refund_balance_transaction,
              :application_fee_refund_balance_transaction,
              :destination_payment_refund_balance_transaction,
              :destination_payment_application_fee_refund

  def initialize(charge,
                 refund,
                 destination_payment_refund,
                 refund_balance_transaction,
                 application_fee_refund_balance_transaction,
                 destination_payment_refund_balance_transaction,
                 destination_payment_application_fee_refund,
                 destination_payment_uncredited: false,
                 merchant_account_currency: nil)
    @charge = charge
    @refund = refund
    @destination_payment_refund = destination_payment_refund
    @refund_balance_transaction = refund_balance_transaction
    @application_fee_refund_balance_transaction = application_fee_refund_balance_transaction
    @destination_payment_refund_balance_transaction = destination_payment_refund_balance_transaction
    @destination_payment_application_fee_refund = destination_payment_application_fee_refund
    @destination_payment_uncredited = destination_payment_uncredited
    @merchant_account_currency = merchant_account_currency

    self.charge_processor_id = StripeChargeProcessor.charge_processor_id
    self.id = refund[:id]
    self.charge_id = refund[:charge]

    self.flow_of_funds = build_flow_of_funds
  end

  private
    def build_flow_of_funds
      gumroad_amount = nil
      merchant_account_gross_amount = nil
      merchant_account_net_amount = nil

      # A destination payment Stripe never credited must reverse to zero in the account's own
      # currency, matching what StripeCharge recorded on the way in. Anything else lands the
      # debit on a different Balance row than the credit it reverses, because balances are keyed
      # on holding_currency (gumroad-private#1608).
      if uncredited_destination_reversal?
        return FlowOfFunds.new(
          issued_amount: calculate_issued_amount,
          settled_amount: calculate_settled_amount,
          gumroad_amount: calculate_gumroad_amount_for_uncredited_destination,
          merchant_account_gross_amount: zero_in_merchant_account_currency,
          merchant_account_net_amount: zero_in_merchant_account_currency
        )
      end

      # Even if the charge involved a destination, the refund may not involve a destination. Refunds only involve the destination if
      # the transfer to the destination is also reversed/refunded.
      if fof_has_destination? && should_refund_application_fees?
        check_merchant_currency_mismatch

        gumroad_amount = calculate_application_fees_refund
        merchant_account_gross_amount = calculate_merchant_gross_amount
        merchant_account_net_amount = calculate_merchant_net_amount
      elsif fof_has_destination?
        gumroad_amount = calculate_gumroad_amount unless charge.on_behalf_of.present?
        merchant_account_gross_amount = calculate_merchant_gross_amount
        merchant_account_net_amount = calculate_merchant_net_amount
      elsif charge.application_fee&.account.present?
        gumroad_amount = FlowOfFunds::Amount.new(
          currency: refund.currency,
          cents: -1 * refund.amount
        )
      else
        gumroad_amount = calculate_settled_amount
      end

      FlowOfFunds.new(
        issued_amount: calculate_issued_amount,
        settled_amount: calculate_settled_amount,
        gumroad_amount:,
        merchant_account_gross_amount:,
        merchant_account_net_amount:
      )
    end

  private
    def calculate_settled_amount
      FlowOfFunds::Amount.new(
        currency: refund_balance_transaction[:currency],
        cents: refund_balance_transaction[:amount]
      )
    end

    def calculate_issued_amount
      FlowOfFunds::Amount.new(
        currency: refund[:currency],
        cents: -1 * refund[:amount]
      )
    end

    def calculate_application_fees_refund
      FlowOfFunds::Amount.new(
        currency: application_fee_refund_balance_transaction[:currency],
        cents: application_fee_refund_balance_transaction[:amount]
      )
    end

    def calculate_gumroad_amount
      FlowOfFunds::Amount.new(
        currency: refund[:currency],
        cents: refund[:amount] - destination_payment_refund[:amount]
      )
    end

    def calculate_merchant_gross_amount
      FlowOfFunds::Amount.new(
        currency: destination_payment_refund_balance_transaction[:currency],
        cents: destination_payment_refund_balance_transaction[:amount]
      )
    end

    def calculate_merchant_net_amount
      cents = destination_payment_refund_balance_transaction[:amount]
      cents += destination_payment_application_fee_refund[:amount] if should_refund_application_fees?
      FlowOfFunds::Amount.new(
        currency: destination_payment_refund_balance_transaction[:currency],
        cents:
      )
    end

    def fof_has_destination?
      charge[:destination] && destination_payment_refund_balance_transaction
    end

    # The charge side decided this destination payment would never be credited and recorded zero
    # for it. The reversal has to agree, whether or not Stripe produced a refund balance
    # transaction for it.
    def uncredited_destination_reversal?
      @destination_payment_uncredited && charge[:destination].present? && @merchant_account_currency.present?
    end

    def zero_in_merchant_account_currency
      FlowOfFunds::Amount.new(currency: @merchant_account_currency, cents: 0)
    end

    # The connected account was credited nothing, so the whole refund comes back out of Gumroad's
    # side. calculate_gumroad_amount would net off a destination refund that does not exist.
    def calculate_gumroad_amount_for_uncredited_destination
      FlowOfFunds::Amount.new(currency: refund[:currency], cents: -1 * refund[:amount])
    end

    def check_merchant_currency_mismatch
      return unless destination_payment_refund_balance_transaction.currency != destination_payment_application_fee_refund.currency

      raise "Destination Payment Application Fee Refund #{destination_payment_application_fee_refund[:id]} should be in the same currency "\
              "as the Destination Payment Refund's Balance Transaction #{destination_payment_refund_balance_transaction[:id]}"
    end

    def should_refund_application_fees?
      application_fee_refund_balance_transaction &&
        destination_payment_application_fee_refund
    end
end
