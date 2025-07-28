# frozen_string_literal: true

class PaypalChargeProcessor
  extend PaypalApiResponse
  extend CurrencyHelper

  DISPLAY_NAME = "PayPal"

  MAXIMUM_DESCRIPTOR_LENGTH = 22

  MAXIMUM_ITEM_NAME_LENGTH = 127

  PAYPAL_VALID_CHARACTERS_REGEX = /[^A-Z0-9. ]/i
  private_constant :PAYPAL_VALID_CHARACTERS_REGEX

  DISPUTE_OUTCOME_SELLER_FAVOUR = %w[RESOLVED_SELLER_FAVOUR CANCELED_BY_BUYER DENIED].freeze
  private_constant :DISPUTE_OUTCOME_SELLER_FAVOUR

  # https://developer.paypal.com/docs/api/orders/v1/
  VALID_TRANSACTION_STATUSES = %w(created approved completed)

  def self.charge_processor_id
    "paypal"
  end

  def self.handle_paypal_event(paypal_event)
    raise "Event for transaction #{paypal_event.try(:[], 'txn_id')} does not have an invoice field" if paypal_event["invoice"].nil?

    event_type = determine_paypal_event_type(paypal_event)
    return if event_type.nil?

    parent_txn_id = paypal_event["parent_txn_id"]

    # Only process dispute won events if the original payment status tells us the payment is in the completed state.
    # Paypal tells us the original reversal (created at dispute creation) was cancelled just before telling us we lost the dispute,
    # so we check the payment status of the main transaction to know what the cancelled reversal message is really telling us.
    return if event_type == ChargeEvent::TYPE_DISPUTE_WON && PaypalChargeProcessor.new.get_charge(parent_txn_id).paypal_payment_status != PaypalApiPaymentStatus::COMPLETED

    currency = paypal_event["mc_currency"].downcase
    fee_cents = Money.new(paypal_event["mc_fee"].to_f * 100, currency).cents if paypal_event["mc_fee"]

    event = ChargeEvent.new
    event.type = event_type
    event.charge_event_id = paypal_event["txn_id"]
    event.charge_processor_id = BraintreeChargeProcessor.charge_processor_id
    event.charge_reference = if paypal_event["invoice"].to_s.starts_with?(Charge::COMBINED_CHARGE_PREFIX)
      charge = Charge.find_by_external_id!(paypal_event["invoice"].sub(Charge::COMBINED_CHARGE_PREFIX, ""))
      Charge::COMBINED_CHARGE_PREFIX + charge.id.to_s
    else
      paypal_event["invoice"]
    end
    event.comment = paypal_event["reason_code"] || paypal_event["payment_status"]
    event.created_at = DateTime.parse(paypal_event["payment_date"])
    event.extras = { "fee_cents" => fee_cents } if fee_cents
    event.flow_of_funds = nil

    ChargeProcessor.handle_event(event)
  end

  # Events like PAYMENT.CAPTURE.REFUNDED, PAYMENT.CAPTURE.COMPLETED are just
  # acknowledgements from Paypal. We get all the information in events(handled
  # in the method below) hence, we don't do anything on these events.
  def self.handle_order_events(event_info)
    # Use the master DB to ensure we're looking at the latest version and have the latest state.
    ActiveRecord::Base.connection.stick_to_primary!
    case event_info["event_type"]
    when PaypalEventType::CUSTOMER_DISPUTE_CREATED
      handle_dispute_created_event(event_info)
    when PaypalEventType::CUSTOMER_DISPUTE_RESOLVED
      handle_dispute_resolved_event(event_info)
    when PaypalEventType::PAYMENT_CAPTURE_COMPLETED
      handle_payment_capture_completed_event(event_info)
    when PaypalEventType::PAYMENT_CAPTURE_DENIED
      handle_payment_capture_denied_event(event_info)
    when PaypalEventType::PAYMENT_CAPTURE_REVERSED,
      PaypalEventType::PAYMENT_CAPTURE_REFUNDED
      handle_payment_capture_refunded_event(event_info)
    end
  end

  def self.handle_dispute_created_event(event_info)
    handle_dispute_event(event_info, ChargeEvent::TYPE_DISPUTE_FORMALIZED)
  rescue StandardError => e
    raise ChargeProcessorError, build_error_message(e.message, event_info)
  end
  private_class_method :handle_dispute_created_event

  def self.handle_dispute_resolved_event(event_info)
    dispute_outcome = event_info["resource"]["dispute_outcome"]["outcome_code"]
    event_type = determine_resolved_dispute_event_type(dispute_outcome)
    handle_dispute_event(event_info, event_type)
  rescue StandardError => e
    raise ChargeProcessorError, build_error_message(e.message, event_info)
  end
  private_class_method :handle_dispute_resolved_event

  def self.handle_payment_capture_completed_event(event_info)
    paypal_fee = event_info.dig("resource", "seller_receivable_breakdown", "paypal_fee")
    return if paypal_fee.blank?

    purchase = Purchase.successful.find_by(stripe_transaction_id: event_info["resource"]["id"])
    return unless purchase

    purchase.processor_fee_cents_currency = paypal_fee["currency_code"]
    purchase.processor_fee_cents = paypal_fee["value"].to_f * unit_scaling_factor(purchase.processor_fee_cents_currency)
    purchase.save!
  end
  private_class_method :handle_payment_capture_completed_event

  def self.handle_payment_capture_denied_event(event_info)
    refund_purchase(capture_id: event_info["resource"]["id"])
  end
  private_class_method :handle_payment_capture_denied_event

  def self.handle_payment_capture_refunded_event(event_info)
    refund_id = event_info["resource"]["id"]
    return if Refund.where(processor_refund_id: refund_id).exists?

    capture_url = event_info["resource"]["links"].find { |link| link["href"].include?("/v2/payments/captures/") }
    capture_id = capture_url["href"].split("/").last

    refunded_amount = event_info["resource"]["seller_payable_breakdown"]["total_refunded_amount"]["value"]
    refund_currency = event_info["resource"]["seller_payable_breakdown"]["total_refunded_amount"]["currency_code"]
    usd_amount_cents = get_usd_cents(refund_currency.downcase, (refunded_amount.to_f * unit_scaling_factor(refund_currency)).to_i)

    refund_purchase(capture_id:, usd_amount_cents:,
                    processor_refund: OpenStruct.new({ id: refund_id, status: event_info["resource"]["status"] }))
  end
  private_class_method :handle_payment_capture_refunded_event

  def self.refund_purchase(capture_id:, usd_amount_cents: nil, processor_refund: nil)
    raise ArgumentError, "No paypal transaction id found in refund webhook" if capture_id.blank?

    purchase = Purchase.find_by(stripe_transaction_id: capture_id)
    return unless purchase&.successful?

    usd_cents_to_refund = usd_amount_cents.present? ?
                            [usd_amount_cents, purchase.gross_amount_refundable_cents].min :
                            purchase.gross_amount_refundable_cents

    flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, usd_cents_to_refund)
    purchase.refund_purchase!(flow_of_funds, purchase.seller_id, processor_refund)
  end
  private_class_method :refund_purchase

  def self.handle_dispute_event(event_info, event_type)
    event = ChargeEvent.new
    event.type = event_type
    event.charge_event_id = event_info["resource"]["dispute_id"]
    event.charge_processor_id = PaypalChargeProcessor.charge_processor_id
    event.charge_id = event_info["resource"]["disputed_transactions"][0]["seller_transaction_id"]
    event.comment = event_info["resource"]["reason"] || event_info["resource"]["status"]
    event.created_at = DateTime.parse(event_info["resource"]["create_time"])
    event.extras = {
      reason: event_info["resource"]["reason"] || event_info["resource"]["status"],
      charge_processor_dispute_id: event_info["resource"]["dispute_id"]
    }
    event.flow_of_funds = nil

    ChargeProcessor.handle_event(event)
  end

  # Dispute Outcome Types
  # RESOLVED_BUYER_FAVOUR - The dispute was resolved in the customer's favor.
  # RESOLVED_SELLER_FAVOUR - The dispute was resolved in the merchant's favor.
  # RESOLVED_WITH_PAYOUT - PayPal provided the merchant or customer with protection and the case is resolved.
  # CANCELED_BY_BUYER - The customer canceled the dispute.
  # ACCEPTED - The dispute was accepted.
  # DENIED - The dispute was denied.
  # Empty - The dispute was not resolved.
  def self.determine_resolved_dispute_event_type(dispute_outcome)
    if DISPUTE_OUTCOME_SELLER_FAVOUR.include? dispute_outcome.upcase
      ChargeEvent::TYPE_DISPUTE_WON
    else
      ChargeEvent::TYPE_DISPUTE_LOST
    end
  end

  def self.generate_billing_agreement_token(shipping: false)
    paypal_rest_api = PaypalRestApi.new
    api_response = paypal_rest_api.generate_billing_agreement_token(shipping:)

    log_paypal_api_response("Generate billing agreement token", nil, api_response)
    if paypal_rest_api.successful_response?(api_response) && api_response.result.token_id.present?
      api_response.result.token_id
    else
      raise ChargeProcessorError, build_error_message(api_response.code, api_response.response)
    end

  rescue => e
    raise ChargeProcessorError, build_error_message(e.message, e.backtrace)
  end

  def self.create_billing_agreement(billing_agreement_token_id:)
    paypal_rest_api = PaypalRestApi.new
    api_response = paypal_rest_api.create_billing_agreement(billing_agreement_token_id:)

    log_paypal_api_response("Create billing agreement", billing_agreement_token_id, api_response)
    if paypal_rest_api.successful_response?(api_response) && api_response.result.id.present?
      open_struct_to_hash(api_response.result).as_json
    else
      raise ChargeProcessorError, build_error_message(api_response.code, api_response.response)
    end

  rescue => e
    raise ChargeProcessorError, build_error_message(e.message, e.backtrace)
  end

  def self.fetch_order(order_id:)
    paypal_rest_api = PaypalRestApi.new
    api_response = paypal_rest_api.fetch_order(order_id:)

    log_paypal_api_response("Fetch Order", order_id, api_response)
    if paypal_rest_api.successful_response?(api_response)
      open_struct_to_hash(api_response.result).as_json
    else
      raise ChargeProcessorError, build_error_message(api_response.code, api_response.response)
    end
  end

  def self.paypal_order_info(purchase)
    merchant_account = purchase.merchant_account || purchase.seller.merchant_account(charge_processor_id)
    currency = merchant_account.currency
    item_name = sanitize_for_paypal(purchase.link.name, MAXIMUM_ITEM_NAME_LENGTH).presence ||
        sanitize_for_paypal(purchase.link.general_permalink, MAXIMUM_ITEM_NAME_LENGTH)

    create_purchase_unit_info(permalink: purchase.link.unique_permalink,
                              item_name:,
                              currency:,
                              merchant_id: merchant_account.charge_processor_merchant_id,
                              descriptor: sanitize_for_paypal(purchase.statement_description, MAXIMUM_DESCRIPTOR_LENGTH),
                              invoice_id: purchase.external_id,
                              price_cents_usd: price_cents(purchase),
                              shipping_cents_usd: purchase.shipping_cents,
                              tax_cents_usd: tax_cents(purchase),
                              fee_cents_usd: purchase.total_transaction_amount_for_gumroad_cents,
                              total_cents_usd: purchase.total_transaction_cents,
                              quantity: purchase.quantity)
  end

  def self.create_order_from_purchase(purchase)
    purchase_unit_info = paypal_order_info(purchase)
    create_order(purchase_unit_info)
  end

  def self.create_order_from_charge(charge)
    purchase_unit_info = paypal_order_info_from_charge(charge)
    create_order(purchase_unit_info)
  end

  def self.paypal_order_info_from_charge(charge)
    merchant_account = charge.merchant_account
    currency = merchant_account.currency
    items = []
    price_cents_usd = shipping_cents_usd = tax_cents_usd = fee_cents_usd = 0

    charge.purchases.each do |purchase|
      item_name = sanitize_for_paypal(purchase.link.name, MAXIMUM_ITEM_NAME_LENGTH).presence ||
        sanitize_for_paypal(purchase.link.general_permalink, MAXIMUM_ITEM_NAME_LENGTH)

      items << { name: item_name,
                 quantity: purchase.quantity,
                 sku: purchase.link.unique_permalink,
                 unit_amount: { currency_code: currency.upcase, value: format_money(price_cents(purchase) / purchase.quantity, currency) },
                 currency:
      }

      price_cents_usd += price_cents(purchase)
      shipping_cents_usd += purchase.shipping_cents
      tax_cents_usd += tax_cents(purchase)
      fee_cents_usd += purchase.total_transaction_amount_for_gumroad_cents
    end

    purchase_unit_info = {}
    purchase_unit_info[:invoice_id] = charge.reference_id_for_charge_processors
    purchase_unit_info[:currency] = currency
    purchase_unit_info[:merchant_id] = merchant_account.charge_processor_merchant_id
    purchase_unit_info[:descriptor] = sanitize_for_paypal(charge.statement_description, MAXIMUM_DESCRIPTOR_LENGTH)

    purchase_unit_info[:items] = items
    purchase_unit_info[:shipping] = format_money(shipping_cents_usd, currency)
    purchase_unit_info[:tax] = format_money(tax_cents_usd, currency)
    purchase_unit_info[:fee] = format_money(fee_cents_usd, currency)

    purchase_unit_info[:price] = items.sum { |item| item[:unit_amount][:value] * item[:quantity] }
    purchase_unit_info[:total] = purchase_unit_info[:price] + purchase_unit_info[:shipping] + purchase_unit_info[:tax]

    purchase_unit_info
  end

  def self.tax_cents(purchase)
    if purchase.gumroad_responsible_for_tax?
      purchase.gumroad_tax_cents
    elsif purchase.was_tax_excluded_from_price
      purchase.tax_cents
    else
      0 # Taxes are included in price in this case.
    end
  end

  def self.price_cents(purchase)
    price_cents = purchase.price_cents - purchase.shipping_cents
    price_cents -= purchase.tax_cents if purchase.was_tax_excluded_from_price
    price_cents
  end

  def self.format_money(money, currency)
    return 0 if money.blank?
    formatted_amount_for_paypal(usd_cents_to_currency(currency, money), currency)
  end

  def self.formatted_amount_for_paypal(cents, currency)
    amount = Money.new(cents, currency).amount

    # PayPal does not accept decimals in TWD, HUF, and JPY currencies
    # Ref: https://developer.paypal.com/docs/api/reference/currency-codes/
    amount = amount.round(0).to_i if %w(TWD HUF JPY).include?(currency.upcase)

    amount
  end

  def self.create_purchase_unit_info(permalink:, item_name:, currency:, merchant_id:, descriptor:, invoice_id: nil, price_cents_usd:,
                                shipping_cents_usd:, fee_cents_usd:, tax_cents_usd:, total_cents_usd:, quantity:)
    purchase_unit_info = {}
    purchase_unit_info[:invoice_id] = invoice_id if invoice_id
    purchase_unit_info[:product_permalink] = permalink
    purchase_unit_info[:item_name] = item_name
    purchase_unit_info[:currency] = currency
    purchase_unit_info[:merchant_id] = merchant_id
    purchase_unit_info[:descriptor] = descriptor

    purchase_unit_info[:price] = format_money(price_cents_usd, currency)
    purchase_unit_info[:shipping] = format_money(shipping_cents_usd, currency)
    purchase_unit_info[:tax] = format_money(tax_cents_usd, currency)
    purchase_unit_info[:fee] = format_money(fee_cents_usd, currency)

    purchase_unit_info[:quantity] = quantity
    purchase_unit_info[:unit_price] = format_money(price_cents_usd / quantity, currency)

    # In case the product currency and merchant account currency are different,
    # there's a chance that after conversion `unit_price * quantity` does not equal to `price`.
    # So we adjust the `price` and `total` such that:
    # price = unit_price * quantity
    # total = price + shipping + tax
    purchase_unit_info[:price] = purchase_unit_info[:unit_price] * purchase_unit_info[:quantity]
    purchase_unit_info[:total] = purchase_unit_info[:price] + purchase_unit_info[:shipping] + purchase_unit_info[:tax]

    purchase_unit_info
  end

  def self.create_order_from_product_info(product_info)
    product = Link.find_by_external_id(product_info[:external_id])
    merchant_account = product.user.merchant_account(charge_processor_id)
    currency = product_info[:currency_code]
    item_name = sanitize_for_paypal(product.name, MAXIMUM_ITEM_NAME_LENGTH).presence ||
        sanitize_for_paypal(product.general_permalink, MAXIMUM_ITEM_NAME_LENGTH)

    purchase_unit_info = create_purchase_unit_info(permalink: product.unique_permalink,
                                                   item_name:,
                                                   currency: merchant_account.currency,
                                                   merchant_id: merchant_account.charge_processor_merchant_id,
                                                   descriptor: sanitize_for_paypal(product.statement_description, MAXIMUM_DESCRIPTOR_LENGTH),
                                                   price_cents_usd: get_usd_cents(currency, product_info[:price_cents].to_i),
                                                   shipping_cents_usd: get_usd_cents(currency, product_info[:shipping_cents].to_i),
                                                   tax_cents_usd: get_usd_cents(currency,
                                                                                product_info[:vat_cents].to_i > 0 ?
                                                                                  product_info[:exclusive_vat_cents].to_i :
                                                                                  product_info[:exclusive_tax_cents].to_i),
                                                   fee_cents_usd: product.gumroad_amount_for_paypal_order(
                                                     amount_cents: get_usd_cents(currency, product_info[:price_cents].to_i),
                                                     affiliate_id: product_info[:affiliate_id],
                                                     vat_cents: get_usd_cents(currency, product_info[:vat_cents].to_i),
                                                     was_recommended: !!product_info[:was_recommended]),
                                                   total_cents_usd: get_usd_cents(currency, product_info[:total_cents].to_i),
                                                   quantity: product_info[:quantity].to_i)

    create_order(purchase_unit_info)
  end

  def self.update_order_from_product_info(paypal_order_id, product_info)
    if paypal_order_id.blank? || product_info.blank?
      Bugsnag.notify("PayPal order ID or product info not present in update order request")
      raise ChargeProcessorError, "PayPal order ID or product info not present in update order request"
    end

    product = Link.find_by_external_id(product_info[:external_id])
    merchant_account = product.user.merchant_account(charge_processor_id)
    currency = product_info[:currency_code]
    item_name = sanitize_for_paypal(product.name, MAXIMUM_ITEM_NAME_LENGTH).presence ||
        sanitize_for_paypal(product.general_permalink, MAXIMUM_ITEM_NAME_LENGTH)

    purchase_unit_info = create_purchase_unit_info(permalink: product.unique_permalink,
                                                   item_name:,
                                                   currency: merchant_account.currency,
                                                   merchant_id: merchant_account.charge_processor_merchant_id,
                                                   descriptor: sanitize_for_paypal(product.statement_description, MAXIMUM_DESCRIPTOR_LENGTH),
                                                   price_cents_usd: get_usd_cents(currency, product_info[:price_cents].to_i),
                                                   shipping_cents_usd: get_usd_cents(currency, product_info[:shipping_cents].to_i),
                                                   tax_cents_usd: get_usd_cents(currency,
                                                                                product_info[:vat_cents].to_i > 0 ?
                                                                                    product_info[:exclusive_vat_cents].to_i :
                                                                                    product_info[:exclusive_tax_cents].to_i),
                                                   fee_cents_usd: product.gumroad_amount_for_paypal_order(
                                                     amount_cents: get_usd_cents(currency, product_info[:price_cents].to_i),
                                                     affiliate_id: product_info[:affiliate_id],
                                                     vat_cents: get_usd_cents(currency, product_info[:vat_cents].to_i),
                                                     was_recommended: !!product_info[:was_recommended]),
                                                   total_cents_usd: get_usd_cents(currency, product_info[:total_cents].to_i),
                                                   quantity: product_info[:quantity].to_i)

    update_order(paypal_order_id, purchase_unit_info)
  end

  def self.create_order(purchase_unit_info)
    if purchase_unit_info.blank?
      Bugsnag.notify("Products are not present in create order request")
      raise ChargeProcessorError, "Products are not present in create order request"
    end
    paypal_rest_api = PaypalRestApi.new
    api_response = paypal_rest_api.create_order(purchase_unit_info:)

    log_paypal_api_response("Create Order", nil, api_response)
    if paypal_rest_api.successful_response?(api_response) && api_response.result.id.present?
      api_response.result.id
    else
      error_message = PaypalChargeProcessor.build_error_message("Failed paypal create order: ", api_response.result.details&.first&.description)
      raise determine_create_order_error(api_response), error_message
    end
  end

  def self.update_order(paypal_order_id, purchase_unit_info)
    paypal_rest_api = PaypalRestApi.new
    api_response = paypal_rest_api.update_order(order_id: paypal_order_id, purchase_unit_info:)

    log_paypal_api_response("Update Order", nil, api_response)
    paypal_rest_api.successful_response?(api_response)
  end

  def self.capture(order_id:, billing_agreement_id: nil)
    paypal_rest_api = PaypalRestApi.new
    api_response = paypal_rest_api.capture(order_id:, billing_agreement_id:)

    log_paypal_api_response("Capture Order", order_id, api_response)
    if paypal_rest_api.successful_response?(api_response) && api_response.result.id.present?
      api_response.result
    else
      error_message = PaypalChargeProcessor.build_error_message("Failed paypal capture order: ", api_response.result.details[0].description)
      raise determine_capture_order_error(api_response), error_message
    end
  end

  def get_chargeable_for_params(params, _gumroad_guid)
    if params[:billing_agreement_id].present?
      PaypalChargeable.new(params[:billing_agreement_id], params[:visual], params[:card_country])
    elsif params[:paypal_order_id].present?
      PaypalApprovedOrderChargeable.new(params[:paypal_order_id], params[:visual], params[:card_country])
    end
  end

  def get_chargeable_for_data(reusable_token, _payment_method_id, _fingerprint,
                              _stripe_setup_intent_id, _stripe_payment_intent_id,
                              _last4, _number_length, visual, _expiry_month, _expiry_year, _card_type,
                              country, _zip_code = nil, merchant_account: nil)
    PaypalChargeable.new(reusable_token, visual, country)
  end

  def search_charge(purchase:)
    if purchase.paypal_order_id.present?
      get_charge_for_order_api(nil, purchase.paypal_order_id)
    end
  end

  def get_charge(charge_id, **_args)
    charge = Charge.find_by(processor_transaction_id: charge_id)
    purchase = Purchase.paypal_orders.where(stripe_transaction_id: charge_id).first unless charge.present?

    if charge
      get_charge_for_order_api(charge_id, charge.paypal_order_id)
    elsif purchase
      get_charge_for_order_api(charge_id, purchase.paypal_order_id)
    else
      get_charge_for_express_checkout_api(charge_id)
    end
  end

  def create_payment_intent_or_charge!(_merchant_account, chargeable, _amount_cents, _amount_for_gumroad_cents, reference,
                                       _description, **_args)
    charge_or_purchase = reference.starts_with?(Charge::COMBINED_CHARGE_PREFIX) ?
                           Charge.find_by_external_id(reference.sub(Charge::COMBINED_CHARGE_PREFIX, "")) :
                           Purchase.find_by_external_id(reference)

    if chargeable.instance_of?(PaypalApprovedOrderChargeable)
      update_invoice_id(order_id: charge_or_purchase.paypal_order_id, invoice_id: reference)
      capture_order(order_id: charge_or_purchase.paypal_order_id)
    else
      paypal_order_id = charge_or_purchase.is_a?(Charge) ?
                          self.class.create_order_from_charge(charge_or_purchase) :
                          self.class.create_order_from_purchase(charge_or_purchase)
      charge_or_purchase.update!(paypal_order_id:)
      charge_or_purchase.purchases.each { |purchase| purchase.update!(paypal_order_id:) } if charge_or_purchase.is_a?(Charge)
      capture_order(order_id: paypal_order_id, billing_agreement_id: chargeable.fingerprint)
    end
  end

  def update_invoice_id(order_id:, invoice_id:)
    paypal_rest_api = PaypalRestApi.new
    api_response = paypal_rest_api.update_invoice_id(order_id:, invoice_id:)

    unless paypal_rest_api.successful_response?(api_response)
      error_message = PaypalChargeProcessor.build_error_message("Failed paypal update order: ",
                                                                api_response.result.details&.first&.description)
      raise determine_update_order_error(api_response), error_message
    end
  end

  def capture_order(order_id:, billing_agreement_id: nil)
    paypal_transaction = self.class.capture(order_id:, billing_agreement_id:)
    capture = paypal_transaction.purchase_units[0].payments.captures[0]

    if capture.status.downcase == PaypalApiPaymentStatus::COMPLETED.downcase ||
        (capture.status.downcase == PaypalApiPaymentStatus::PENDING.downcase &&
            capture.status_details.reason.upcase == "PENDING_REVIEW")
      charge = PaypalCharge.new(paypal_transaction_id: capture.id,
                                order_api_used: true,
                                payment_details: paypal_transaction)
      PaypalChargeIntent.new(charge:)
    else
      if capture.status.downcase == PaypalApiPaymentStatus::PENDING.downcase &&
          capture.status_details.reason.upcase == "ECHECK"
        merchant_id = paypal_transaction.purchase_units[0].payee.merchant_id
        refund!(capture.id,
                merchant_account: MerchantAccount.find_by(charge_processor_merchant_id: merchant_id),
                paypal_order_purchase_unit_refund: true)
      end
      raise ChargeProcessorCardError.new("paypal_capture_failure",
                                         "PayPal transaction failed with status #{capture.status}",
                                         charge_id: capture.id)
    end
  end

  def refund!(charge_id, amount_cents: nil, merchant_account: nil, paypal_order_purchase_unit_refund: nil, **_args)
    if paypal_order_purchase_unit_refund
      refund_response = refund_order_purchase_unit!(charge_id, merchant_account, amount_cents)
      PaypalOrderRefund.new(refund_response, charge_id)
    else
      if amount_cents.nil?
        refund_request = paypal_api.build_refund_transaction(TransactionID: charge_id, RefundType: PaypalApiRefundType::FULL)
      else
        amount = amount_cents / 100.0
        refund_request = paypal_api.build_refund_transaction(TransactionID: charge_id, RefundType: PaypalApiRefundType::PARTIAL, Amount: amount)
      end

      refund_response = paypal_api.refund_transaction(refund_request)

      if refund_response.errors.present?
        error = refund_response.errors.first
        error_code = error.ErrorCode.to_i
        case error_code
        when PaypalApiErrorCodeRange::REFUND_VALIDATION
          raise ChargeProcessorAlreadyRefundedError, error.LongMessage if error.LongMessage[/been fully refunded/].present?

          raise ChargeProcessorInvalidRequestError, PaypalChargeProcessor.build_error_message(error_code, error.LongMessage)
        when PaypalApiErrorCodeRange::REFUND_FAILURE
          raise ChargeProcessorCardError.new(error_code, error.LongMessage, charge_id:)
        else
          raise ChargeProcessorInvalidRequestError, PaypalChargeProcessor.build_error_message(error_code, error.LongMessage)
        end
      end

      PaypalChargeRefund.new(refund_response, charge_id)
    end
  rescue *INTERNET_EXCEPTIONS => e
    raise ChargeProcessorUnavailableError, e
  end

  def holder_of_funds(_merchant_account)
    HolderOfFunds::GUMROAD
  end

  def transaction_url(charge_id)
    sub_domain = Rails.env.production? ? "history" : "sandbox"
    "https://#{sub_domain}.paypal.com/us/cgi-bin/webscr?cmd=_history-details-from-hub&id=#{charge_id}"
  end

  private_class_method
  def self.determine_paypal_event_type(paypal_event)
    case paypal_event["payment_status"]
    when "Reversed"
      ChargeEvent::TYPE_DISPUTE_FORMALIZED
    when "Canceled_Reversal"
      ChargeEvent::TYPE_DISPUTE_WON
    when "Completed"
      ChargeEvent::TYPE_INFORMATIONAL
    end
  end

  private_class_method
  def self.build_error_message(error_code, error_message)
    "#{error_code}|#{error_message}"
  end

  private_class_method
  def self.paypal_api
    PayPal::SDK::Merchant::API.new
  end

  def self.log_paypal_api_response(api_label, resource_id, api_response)
    Rails.logger.info("#{api_label} (#{resource_id}) headers => #{api_response.headers.inspect}")
    Rails.logger.info("#{api_label} (#{resource_id}) body => #{api_response.inspect}")
  end

  private
    def paypal_api
      PaypalChargeProcessor.paypal_api
    end

    def get_charge_for_express_checkout_api(charge_id)
      transaction_details = paypal_api.get_transaction_details(paypal_api.build_get_transaction_details(TransactionID: charge_id))

      if transaction_details.errors.present?
        error = transaction_details.errors.first
        raise ChargeProcessorInvalidRequestError, PaypalChargeProcessor.build_error_message(error.error_code, error.LongMessage)
      end

      PaypalCharge.new(paypal_transaction_id: charge_id,
                       order_api_used: false,
                       payment_details: {
                         paypal_payment_info: transaction_details.PaymentTransactionDetails.PaymentInfo,
                         paypal_payer_info: transaction_details.PaymentTransactionDetails.PayerInfo
                       })
    rescue *INTERNET_EXCEPTIONS => e
      raise ChargeProcessorUnavailableError, e
    end

    def get_charge_for_order_api(capture_id, order_id)
      order_details = PaypalChargeProcessor.fetch_order(order_id:)
      capture_id ||= order_details["purchase_units"][0]["payments"]["captures"][0]["id"]
      PaypalCharge.new(paypal_transaction_id: capture_id,
                       order_api_used: true,
                       payment_details: order_details)
    end

    # Types of error which could be raised while refunding using the Orders API:
    #
    # INTERNAL_ERROR (An internal service error occurred)
    #
    # MISSING_ARGS (Missing Required Arguments)
    #
    # INVALID_RESOURCE_ID (Requested resource ID was not found)
    #
    # PERMISSION_DENIED (Permission denied)
    #
    # TRANSACTION_REFUSED (Request was refused)
    #
    # INVALID_PAYER_ID (Payer ID is invalid)
    #
    # INSTRUMENT_DECLINED (Processor or bank declined funding instrument or it cannot be used for this payment)
    #
    # RISK_CONTROL_MAX_AMOUNT (Request was refused)
    #
    # REFUND_ALREADY_INITIATED (Refund refused. Refund was already issued for transaction)
    #
    # REFUND_FAILED_INSUFFICIENT_FUNDS (Refund failed due to insufficient funds in your PayPal account)
    #
    # EXTDISPUTE_REFUND_FAILED_INSUFFICIENT_FUNDS (Refund failed due to insufficient funds in seller's PayPal account)
    def refund_order_purchase_unit!(capture_id, merchant_account, amount_cents)
      paypal_rest_api = PaypalRestApi.new
      api_response = paypal_rest_api.refund(capture_id:, merchant_account:,
                                            amount: self.class.format_money(amount_cents, merchant_account.currency))

      self.class.log_paypal_api_response("Refund Order Purchase Unit", capture_id, api_response)
      if paypal_rest_api.successful_response?(api_response)
        api_response.result
      else
        error_message = PaypalChargeProcessor.build_error_message("Failed refund capture id - #{capture_id}", api_response.result.details[0].description)
        raise determine_refund_order_error(api_response), error_message
      end
    end

    def self.determine_create_order_error(api_response)
      if api_response.result.name == "INTERNAL_ERROR"
        ChargeProcessorUnavailableError
      elsif api_response.result.name == "UNPROCESSABLE_ENTITY" &&
          api_response.result.details&.first&.issue == "PAYEE_ACCOUNT_RESTRICTED"
        ChargeProcessorPayeeAccountRestrictedError
      else
        ChargeProcessorInvalidRequestError
      end
    end

    def determine_update_order_error(api_response)
      if api_response.result.name == "INTERNAL_ERROR"
        ChargeProcessorUnavailableError
      else
        ChargeProcessorInvalidRequestError
      end
    end

    def self.determine_capture_order_error(api_response)
      if api_response.result.name == "INTERNAL_ERROR"
        ChargeProcessorUnavailableError
      elsif api_response.result.name == "UNPROCESSABLE_ENTITY" &&
        api_response.result.details[0].issue == "AGREEMENT_ALREADY_CANCELLED"
        ChargeProcessorPayerCancelledBillingAgreementError
      elsif api_response.result.name == "UNPROCESSABLE_ENTITY" &&
        api_response.result.details[0].issue == "TRANSACTION_REFUSED"
        ChargeProcessorPaymentDeclinedByPayerAccountError
      elsif api_response.result.name == "UNPROCESSABLE_ENTITY" &&
        api_response.result.details[0].issue == "PAYEE_ACCOUNT_RESTRICTED"
        ChargeProcessorPayeeAccountRestrictedError
      elsif api_response.result.name == "UNPROCESSABLE_ENTITY" &&
        api_response.result.details[0].issue == "PAYER_CANNOT_PAY"
        ChargeProcessorPaymentDeclinedByPayerAccountError
      else
        ChargeProcessorInvalidRequestError
      end
    end

    def determine_refund_order_error(api_response)
      if api_response.result.name == "INTERNAL_ERROR"
        ChargeProcessorUnavailableError
      elsif api_response.result.name == "UNPROCESSABLE_ENTITY" &&
          api_response.result.details[0].issue == "CAPTURE_FULLY_REFUNDED"
        ChargeProcessorAlreadyRefundedError
      elsif api_response.result.name == "UNPROCESSABLE_ENTITY" &&
          api_response.result.details[0].issue == "REFUND_FAILED_INSUFFICIENT_FUNDS"
        ChargeProcessorInsufficientFundsError
      else
        ChargeProcessorInvalidRequestError
      end
    end

    def self.sanitize_for_paypal(string, max_length)
      string.gsub(PAYPAL_VALID_CHARACTERS_REGEX, "").to_s.strip[0...max_length]
    end
end
