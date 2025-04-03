# frozen_string_literal: true

class StripeCharge < BaseProcessorCharge
  # Public: Create a BaseProcessorCharge from a Stripe::Charge and a Stripe::BalanceTransaction
  def initialize(stripe_charge, stripe_charge_balance_transaction, stripe_application_fee_balance_transaction,
                 stripe_destination_payment_balance_transaction, stripe_destination_transfer)
    self.charge_processor_id = StripeChargeProcessor.charge_processor_id
    return if stripe_charge.nil?

    self.id = stripe_charge[:id]
    self.status = stripe_charge[:status].to_s.downcase
    self.refunded = stripe_charge[:refunded]
    self.disputed = stripe_charge[:dispute].present?

    stripe_fee_detail = stripe_charge_balance_transaction[:fee_details].find { |fee_detail| fee_detail[:type] == "stripe_fee" }
    if stripe_fee_detail.present?
      self.fee_currency = stripe_fee_detail[:currency]
      self.fee = stripe_fee_detail[:amount]
    end

    self.flow_of_funds = build_flow_of_funds(stripe_charge, stripe_charge_balance_transaction, stripe_application_fee_balance_transaction,
                                             stripe_destination_payment_balance_transaction, stripe_destination_transfer)


    return if stripe_charge["payment_method_details"].nil?

    fetch_risk_level(stripe_charge)
    fetch_card_details_from(stripe_charge)
  end

  private
    def fetch_risk_level(stripe_charge)
      self.risk_level = stripe_charge[:outcome][:risk_level]
    end

    def fetch_card_details_from(stripe_charge)
      payment_method_details = stripe_charge[:payment_method_details]
      billing_details = stripe_charge[:billing_details]
      payment_card = payment_method_details[:card]
      self.card_fingerprint = payment_card[:fingerprint]
      self.card_instance_id = stripe_charge[:payment_method]
      self.card_last4 = payment_card[:last4]
      if payment_card[:brand].present?
        card_type = StripeCardType.to_new_card_type(payment_card[:brand])
        self.card_type = card_type
        self.card_number_length = ChargeableVisual.get_card_length_from_card_type(card_type)
      end
      self.card_expiry_month = payment_card[:exp_month]
      self.card_expiry_year = payment_card[:exp_year]
      self.card_zip_code = billing_details[:address][:postal_code]
      self.card_country = payment_card[:country]
      self.zip_check_result = case payment_card[:checks][:address_postal_code_check]
                              when "pass"
                                true
                              when "fail"
                                false
      end
    end

    def build_flow_of_funds(stripe_charge, stripe_charge_balance_transaction, stripe_application_fee_balance_transaction,
                            stripe_destination_payment_balance_transaction, stripe_destination_transfer)
      return if stripe_charge[:destination] && stripe_application_fee_balance_transaction.nil? &&
        stripe_destination_transfer.nil?

      issued_amount = FlowOfFunds::Amount.new(currency: stripe_charge[:currency],
                                              cents: stripe_charge[:amount])

      settled_amount = FlowOfFunds::Amount.new(currency: stripe_charge_balance_transaction[:currency],
                                               cents: stripe_charge_balance_transaction[:amount])

      if stripe_charge[:destination]
        if stripe_application_fee_balance_transaction.present?
          # For old charges with `application_fee_amount` parameter, we get the gumroad amount from the
          # application_fee object attached to the charge.
          gumroad_amount_currency = stripe_application_fee_balance_transaction[:currency]
          gumroad_amount_cents = stripe_application_fee_balance_transaction[:amount]
        else
          # For new charges with `transfer_data[amount]` parameter instead of `application_fee_amoount`, there's
          # no application_fee object attached to the charge so we calculate the gumroad amount as difference between
          # the total charge amount and the amount transferred to the connect account.
          gumroad_amount_currency = stripe_charge[:currency]
          gumroad_amount_cents = stripe_charge[:amount] - stripe_destination_transfer[:amount]
        end
        gumroad_amount = FlowOfFunds::Amount.new(currency: gumroad_amount_currency, cents: gumroad_amount_cents)

        # Note: The settled and merchant account gross amount will always be the same with Stripe Connect.
        # The transaction settles in the merchant account currency and the gross amount is the full settled amount.

        merchant_account_gross_amount = FlowOfFunds::Amount.new(currency: stripe_destination_payment_balance_transaction[:currency],
                                                                cents: stripe_destination_payment_balance_transaction[:amount])

        merchant_account_net_amount = FlowOfFunds::Amount.new(currency: stripe_destination_payment_balance_transaction[:currency],
                                                              cents: stripe_destination_payment_balance_transaction[:net])
      elsif stripe_application_fee_balance_transaction.present?
        # For direct charges in case of Stripe Connect accounts, there will be no destination on the Stripe charge,
        # but there will be an associated application_fee. We get the gumroad amount from the
        # application_fee object attached to the charge in this case.
        gumroad_amount_currency = stripe_application_fee_balance_transaction[:currency]
        gumroad_amount_cents = stripe_application_fee_balance_transaction[:amount]

        gumroad_amount = FlowOfFunds::Amount.new(currency: gumroad_amount_currency, cents: gumroad_amount_cents)

        # Note: The settled and merchant account gross amount will always be the same with Stripe Connect.
        # The transaction settles in the merchant account currency and the gross amount is the full settled amount.

        merchant_account_gross_amount = FlowOfFunds::Amount.new(currency: stripe_charge_balance_transaction[:currency],
                                                                cents: stripe_charge_balance_transaction[:amount])

        merchant_account_net_amount = FlowOfFunds::Amount.new(currency: stripe_charge_balance_transaction[:currency],
                                                              cents: stripe_charge_balance_transaction[:net])
      else
        gumroad_amount = settled_amount
        merchant_account_gross_amount = nil
        merchant_account_net_amount = nil
      end

      FlowOfFunds.new(
        issued_amount:,
        settled_amount:,
        gumroad_amount:,
        merchant_account_gross_amount:,
        merchant_account_net_amount:
      )
    end
end
