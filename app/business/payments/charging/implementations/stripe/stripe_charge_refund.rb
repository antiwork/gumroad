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
                 destination_payment_application_fee_refund)

    @charge = charge
    @refund = refund
    @destination_payment_refund = destination_payment_refund
    @refund_balance_transaction = refund_balance_transaction
    @application_fee_refund_balance_transaction = application_fee_refund_balance_transaction
    @destination_payment_refund_balance_transaction = destination_payment_refund_balance_transaction
    @destination_payment_application_fee_refund = destination_payment_application_fee_refund

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
