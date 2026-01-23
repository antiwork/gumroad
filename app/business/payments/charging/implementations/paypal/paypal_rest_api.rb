# frozen_string_literal: true

class PaypalRestApi
  include CurrencyHelper

  PAYPAL_INTENT_CAPTURE = "CAPTURE"

  def initialize
    paypal_environment = Rails.env.production? ?
                             PayPal::LiveEnvironment.new(PAYPAL_PARTNER_CLIENT_ID, PAYPAL_PARTNER_CLIENT_SECRET) :
                             PayPal::SandboxEnvironment.new(PAYPAL_PARTNER_CLIENT_ID, PAYPAL_PARTNER_CLIENT_SECRET)
    @paypal_client = PayPal::PayPalHttpClient.new(paypal_environment)
  end

  def new_request(path:, verb:)
    OpenStruct.new({
                     path:,
                     verb:,
                     headers: rest_api_headers,
                     body: {},
                   })
  end

  def generate_billing_agreement_token(shipping: false)
    @request = new_request(path: "/v1/billing-agreements/agreement-tokens", verb: "POST")
    @request.body = {
      "payer": { "payment_method": "PAYPAL" },
      "plan": {
        "type": "CHANNEL_INITIATED_BILLING",
        "merchant_preferences": {
          "return_url": "#{UrlService.domain_with_protocol}/paypal_ba_return",
          "cancel_url": "#{UrlService.domain_with_protocol}/paypal_ba_cancel",
          "accepted_pymt_type": "INSTANT",
          "skip_shipping_address": !shipping
        }
      }
    }
    execute_request
  end

  def create_billing_agreement(billing_agreement_token_id:)
    @request = new_request(path: "/v1/billing-agreements/agreements", verb: "POST")
    @request.headers["PayPal-Request-Id"] = "create-billing-agreement-#{billing_agreement_token_id}"
    @request.body = {
      "token_id": billing_agreement_token_id
    }
    execute_request
  end

  def create_order(purchase_unit_info:)
    @request = new_request(path: "/v2/checkout/orders", verb: "POST")
    if Rails.env.production? && purchase_unit_info[:invoice_id].present?
      @request.headers["PayPal-Request-Id"] = "create-order-#{purchase_unit_info[:invoice_id]}"
    end
    @request.headers["Prefer"] = "return=representation"
    order_params = {
      intent: PAYPAL_INTENT_CAPTURE,
      purchase_units: [purchase_unit(purchase_unit_info)],
      application_context: { brand_name: "Gumroad", shipping_preference: "NO_SHIPPING" }
    }
    @request.body = order_params
    execute_request
  end

  def update_invoice_id(order_id:, invoice_id:)
    @request = new_request(path: "/v2/checkout/orders/#{order_id}", verb: "PATCH")
    @request.headers["Prefer"] = "return=representation"
    @request.body = [{ op: "add", path: "/purchase_units/@reference_id=='default'/invoice_id", value: invoice_id }]
    execute_request
  end

  def update_order(order_id:, purchase_unit_info:)
    @request = new_request(path: "/v2/checkout/orders/#{order_id}", verb: "PATCH")
    @request.headers["Prefer"] = "return=representation"
    @request.body = [{ op: "replace", path: "/purchase_units/@reference_id=='default'", value: purchase_unit(purchase_unit_info) }]
    execute_request
  end

  def fetch_order(order_id:)
    @request = new_request(path: "/v2/checkout/orders/#{order_id}", verb: "GET")
    execute_request
  end

  def capture(order_id:, billing_agreement_id:)
    @request = new_request(path: "/v2/checkout/orders/#{order_id}/capture", verb: "POST")
    @request.headers["PayPal-Request-Id"] = "capture-#{order_id}"
    @request.headers["Prefer"] = "return=representation"
    if billing_agreement_id.present?
      @request.body = {
        "payment_source": {
          "token": {
            "id": billing_agreement_id,
            "type": "BILLING_AGREEMENT"
          }
        }
      }
    end
    execute_request
  end

  def refund(capture_id:, merchant_account: nil, amount: nil)
    paypal_account_id = merchant_account&.charge_processor_merchant_id
    currency = merchant_account&.currency

    # If for some reason we don't have the paypal account id or currency in our records,
    # fetch the original order and get those details from it
    if paypal_account_id.blank? || currency.blank?
      purchase = Purchase.where(stripe_transaction_id: capture_id).last
      raise ArgumentError, "No purchase found for paypal transaction id #{capture_id}" unless purchase.present?

      paypal_order = fetch_order(order_id: purchase.paypal_order_id).result
      if paypal_order.purchase_units.present?
        paypal_account_id ||= paypal_order.purchase_units[0].payee.merchant_id
        currency ||= paypal_order.purchase_units[0].amount.currency_code
      end
    end

    @request = new_request(path: "/v2/payments/captures/#{capture_id}/refund", verb: "POST")
    @request.headers["PayPal-Request-Id"] = "refund-#{capture_id}-#{amount}-#{timestamp}"
    @request.headers["Prefer"] = "return=representation"
    @request.headers["Paypal-Auth-Assertion"] = paypal_auth_assertion_header(paypal_account_id)
    @request.body = refund_body(amount, currency)
    execute_request
  end

  def successful_response?(api_response)
    (200...300).include?(api_response.status_code)
  end

  private
    def purchase_unit(purchase_unit_info)
      currency = purchase_unit_info[:currency]

      info = {
        amount: {
          currency_code: currency,
          value: purchase_unit_info[:total],
          breakdown: {
            shipping: money_object(currency:, value: purchase_unit_info[:shipping]),
            tax_total: money_object(currency:, value: purchase_unit_info[:tax]),
            item_total: money_object(currency:, value: purchase_unit_info[:price])
          }
        },
        payee: {
          merchant_id: purchase_unit_info[:merchant_id]
        },
        items: purchase_unit_info[:items].presence || [
          {
            name: purchase_unit_info[:item_name],
            unit_amount: money_object(currency: purchase_unit_info[:currency], value: purchase_unit_info[:unit_price]),
            quantity: purchase_unit_info[:quantity],
            sku: purchase_unit_info[:product_permalink]
          }
        ],
        soft_descriptor: purchase_unit_info[:descriptor],
        payment_instruction: {
          platform_fees: [
            {
              amount: money_object(currency:, value: purchase_unit_info[:fee]),
              payee: {
                email_address: PAYPAL_PARTNER_EMAIL
              }
            }]
        }
      }

      info[:invoice_id] = purchase_unit_info[:invoice_id] if purchase_unit_info[:invoice_id]

      info
    end

    def refund_body(amount, currency)
      body = {}
      body[:amount] = money_object(currency:, value: amount) if amount.to_f > 0
      body
    end

    def timestamp
      Time.current.to_f.to_s.delete(".")
    end

    def rest_api_headers
      {
        "Accept" => "application/json",
        "Accept-Language" => "en_US",
        "Authorization" => PaypalPartnerRestCredentials.new.auth_token,
        "Content-Type" => "application/json",
        "PayPal-Partner-Attribution-Id" => PAYPAL_BN_CODE,
        "PayPal-Request-Id" => timestamp
      }
    end

    def paypal_auth_assertion_header(seller_merchant_id)
      header_part_one = { alg: "none" }.to_json
      header_part_two = { payer_id: seller_merchant_id, iss: PAYPAL_PARTNER_CLIENT_ID }.to_json

      "#{Base64.strict_encode64(header_part_one)}.#{Base64.strict_encode64(header_part_two)}."
    end

    def money_object(currency:, value:)
      { currency_code: currency.upcase, value: }
    end

    def execute_request
      Rails.logger.info "Making Paypal request:: #{LogRedactor.redact(@request)}"
      @paypal_client.execute(@request)
    rescue PayPalHttp::HttpError => e
      Rails.logger.error "Paypal request failed:: Status code: #{e.status_code}, Result: #{e.result.inspect}"
      OpenStruct.new(status_code: e.status_code, result: e.result)
    end
end
