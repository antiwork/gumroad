# frozen_string_literal: true

class PaypalCharge < BaseProcessorCharge
  include CurrencyHelper

  attr_accessor :paypal_payment_status, :card_visual

  def initialize(paypal_transaction_id:, order_api_used:, payment_details: {})
    self.charge_processor_id = PaypalChargeProcessor.charge_processor_id
    self.id = paypal_transaction_id

    load_transaction_details(paypal_transaction_id, order_api_used, payment_details)
  end

  private
    def load_transaction_details(paypal_transaction_id, order_api_used, payment_details)
      if order_api_used
        load_transaction_details_for_paypal_order_api(paypal_transaction_id, payment_details)
      else
        load_transaction_details_for_express_checkout_api(payment_details)
      end
    end

    def load_transaction_details_for_express_checkout_api(payment_details)
      self.fee = fee_cents(payment_details[:paypal_payment_info].FeeAmount.value,
                           payment_details[:paypal_payment_info].FeeAmount.currencyID)
      self.paypal_payment_status = self.status = payment_details[:paypal_payment_info].PaymentStatus
      self.refunded = status.downcase == PaypalApiPaymentStatus::REFUNDED.downcase
      self.flow_of_funds = nil

      return if payment_details[:paypal_payer_info].nil?

      self.card_fingerprint = PaypalCardFingerprint.build_paypal_fingerprint(payment_details[:paypal_payer_info].PayerID)
      self.card_country = payment_details[:paypal_payer_info].PayerCountry
      self.card_type = CardType::PAYPAL
    end

    def load_transaction_details_for_paypal_order_api(capture_id, order_details)
      return if capture_id.blank?

      capture_details = fetch_capture_details(capture_id, order_details)
      if capture_details.dig("seller_receivable_breakdown", "paypal_fee").present?
        self.fee_currency = capture_details["seller_receivable_breakdown"]["paypal_fee"]["currency_code"]
        self.fee = fee_cents(capture_details["seller_receivable_breakdown"]["paypal_fee"]["value"],
                             fee_currency)
      end
      self.paypal_payment_status = capture_details["status"]
      self.status = capture_details["status"].to_s.downcase
      self.refunded = status == PaypalApiPaymentStatus::REFUNDED.downcase
      self.card_fingerprint = PaypalCardFingerprint.build_paypal_fingerprint(order_details["payer"]["email_address"])
      self.card_visual = order_details["payer"]["email_address"]
      self.card_country = order_details["payer"]["address"]["country_code"]
      self.card_type = CardType::PAYPAL
      # Don't create flow of funds for paypal charge as we don't use anything from it except for gumroad amount's currency
      # for affiliate balance creation, but as now gumroad amount's currency can be non-usd, we can't use it as affiliate balance
      # needs to be in usd always, so we'll simply generate a simple flow of funds for purchases via paypal for that purpose.
      # Keeping the method body for now in case we need it later for some reason and for debugging.
      # self.flow_of_funds = build_flow_of_funds(capture_details) if capture_details.present?
    end

    def fee_cents(fee_amount, currency)
      fee_amount.to_f * unit_scaling_factor(currency)
    end

    def fetch_capture_details(capture_id, order_details)
      order_details["purchase_units"].detect do |purchase_unit|
        purchase_unit["payments"]["captures"][0]["id"] == capture_id
      end["payments"]["captures"][0]
    end

    def build_flow_of_funds(capture_details)
      merchant_account_gross_amount = settled_amount = issued_amount = FlowOfFunds::Amount.new(
        currency: capture_details["seller_receivable_breakdown"]["gross_amount"]["currency_code"].downcase,
        cents: capture_details["seller_receivable_breakdown"]["gross_amount"]["value"])

      gumroad_amount = FlowOfFunds::Amount.new(
        currency: capture_details["seller_receivable_breakdown"]["platform_fees"][0]["amount"]["currency_code"].downcase,
        cents: capture_details["seller_receivable_breakdown"]["platform_fees"][0]["amount"]["value"])

      merchant_account_net_amount = FlowOfFunds::Amount.new(
        currency: capture_details["seller_receivable_breakdown"]["net_amount"]["currency_code"].downcase,
        cents: capture_details["seller_receivable_breakdown"]["net_amount"]["value"])

      # These amounts are not actually used right now as we don't need to create balance-transactions for seller
      # in case of paypal native txns. Only the currency from gumroad_amount (which is always USD) is used
      # to create affiliate balance-transactions.
      FlowOfFunds.new(
        issued_amount:,
        settled_amount:,
        gumroad_amount:,
        merchant_account_gross_amount:,
        merchant_account_net_amount:
      )
    end
end
