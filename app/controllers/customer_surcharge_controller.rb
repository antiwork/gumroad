# frozen_string_literal: true

class CustomerSurchargeController < ApplicationController
  include CurrencyHelper

  def calculate_all
    products = params.require(:products)
    # Malformed requests can send `products` as a raw string (or an array containing
    # strings) instead of an array of product hashes. Reject those with a 400 instead
    # of letting `products.each` / `item[:permalink]` raise a NoMethodError.
    unless products.is_a?(Array) && products.all? { |item| item.is_a?(ActionController::Parameters) || item.is_a?(Hash) }
      return head :bad_request
    end

    vat_id_valid = false
    has_vat_id_input = false
    shipping_rate = 0
    tax_rate = 0
    tax_included_rate = 0
    subtotal = 0
    quote_line_items = []
    rates_by_listed_currency = {}
    # A buyer-currency quote needs a canonical money breakdown for every line the browser
    # will display; if any request line can't produce one (unknown product, missing
    # subscription), the quote is withheld and the cart falls back to canonical USD.
    all_lines_quotable = true
    products.each do |item|
      product = Link.find_by_unique_permalink(item[:permalink])
      unless product
        all_lines_quotable = false
        next
      end
      listed_currency = product.price_currency_type.to_s.downcase
      surcharges = calculate_surcharges(
        product,
        item[:quantity],
        item[:price].to_d.to_i,
        subscription_id: item[:subscription_id],
        recommended_by: item[:recommended_by],
        rate: rates_by_listed_currency.fetch(listed_currency, :unset)
      )
      unless surcharges
        all_lines_quotable = false
        next
      end
      rates_by_listed_currency[listed_currency] = surcharges[:rate]
      tax_result = surcharges[:sales_tax_result]
      vat_id_valid = tax_result.business_vat_status == :valid
      has_vat_id_input ||= tax_result.to_hash[:has_vat_id_input]
      # Already USD: calculate_surcharges converts each listed rate term the same way
      # Purchase#calculate_shipping does. Do not convert the aggregate again: convert(sum)
      # and sum(convert) disagree by a cent under non-integer FX rates.
      shipping_usd_cents = surcharges[:shipping_rate]
      shipping_rate += shipping_usd_cents
      tax_cents = tax_result.tax_cents
      if tax_cents > 0
        tax_rate += tax_cents
      end
      subtotal += tax_result.price_cents
      charge_details = buyer_currency_charge_details(product:, item:, surcharges:)
      unless charge_details
        all_lines_quotable = false
        next
      end
      quote_line_items << Checkout::BuyerCurrencyQuote::LineItem.from_surcharge(
        permalink: item[:permalink].to_s,
        product:,
        tax_result:,
        tip_cents: item[:tip_cents],
        shipping_usd_cents:,
        charge_tax_result: charge_details[:surcharges]&.fetch(:sales_tax_result),
        charge_tip_cents: charge_details[:tip_cents],
        charge_shipping_usd_cents: charge_details[:surcharges] ? charge_details[:surcharges].fetch(:shipping_rate) : 0,
        charge_now: charge_details[:charge_now],
        later_charge_kind: charge_details[:kind],
        later_charge_price_cents: charge_details[:later_price_cents],
        # The rate `calculate_surcharges` used a moment earlier to convert this line's
        # shipping to canonical USD cents — not a fresh `get_rate` call (gumroad-private#1958,
        # Greptile review on #7149: a second independent read here can straddle a rate
        # refresh and disagree with the first one even within a single request).
        listed_currency_rate: surcharges[:rate]
      )
    end

    detected_buyer_currency = buyer_currency_for_ip(request.remote_ip)
    requested_buyer_currency = Checkout::BuyerCurrencyQuote.normalize_requested_currency(params[:buyer_currency])
    quote_currency = requested_buyer_currency || detected_buyer_currency
    quote_props = buyer_currency_quote_props(
      line_items: all_lines_quotable ? quote_line_items : nil,
      # Sum the per-line integers: rounding the running totals once can disagree
      # with charge-time line totals, and a quote that does not reconcile is refused.
      canonical_total_cents: quote_line_items.sum(&:canonical_total_cents),
      currency: quote_currency
    )
    # create() refuses a mixed/unquotable cart. Advertising those currencies would
    # let the picker claim a presentment the charge will never honor. `cart_quotable?` asks the
    # quote service the same question for the gates that hold in every currency (zero total,
    # more sellers than it will quote, a mixed recurring cart, ...), so a cart no currency can
    # get past offers US dollars alone rather than a menu whose entries disappear one by one as
    # the buyer tries them.
    quotable_cart = all_lines_quotable && Checkout::BuyerCurrencyQuote.cart_quotable?(
      line_items: quote_line_items,
      canonical_total_cents: quote_line_items.sum(&:canonical_total_cents)
    )
    available = available_buyer_currencies(quotable_cart ? quote_line_items : [])
    # What is left can still fail for a reason specific to one currency (a settlement mismatch
    # on the seller's account, or a cart uniformly listed in it). Don't advertise the one we just
    # attempted to quote; the checkout tells the buyer their choice was refused.
    if quote_currency.present? && quote_currency != Currency::USD && quote_props.nil? &&
       !direct_listed_currency_offered_for_cart?(quote_line_items, quote_currency)
      available = available.reject { |entry| entry[:code] == quote_currency }
    end

    render json: {
      vat_id_valid:,
      has_vat_id_input:,
      shipping_rate_cents: shipping_rate,
      tax_cents: tax_rate.round.to_i,
      tax_included_cents: tax_included_rate.round.to_i,
      subtotal: subtotal.round.to_i,
      # Unlike the agreement total above, this includes only the tax due on an installment's
      # first payment. Payment surfaces must use the amount the charge path will create now.
      charge_canonical_total_cents: all_lines_quotable ? quote_line_items.sum(&:charge_canonical_total_cents) : nil,
      buyer_currency_quote: quote_props,
      detected_buyer_currency:,
      available_buyer_currencies: available
    }
  end

  private
    def buyer_currency_quote_props(line_items:, canonical_total_cents:, currency: nil)
      return if line_items.nil?

      quote = Checkout::BuyerCurrencyQuote.create(
        line_items:,
        canonical_total_cents: canonical_total_cents.round.to_i,
        ip: request.remote_ip,
        currency:
      )
      return if quote.blank?

      {
        token: quote.token,
        currency: quote.currency,
        canonical_total_cents: quote.canonical_total_cents,
        presentment_total_cents: quote.presentment_total_cents,
        charge_presentment_total_cents: quote.charge_presentment_total_cents,
        future_installments_presentment_total_cents: quote.future_installments_presentment_total_cents,
        # What one canonical US dollar cent is worth in the buyer's currency. The browser uses
        # this only for the two amounts it still converts itself, the discount row and the tip
        # the buyer types; every amount that is actually charged comes from the per-line
        # allocations below. A single-charge cart reports the exact minor-unit rate from its one
        # locked quote; a cart spanning several sellers has one quote per seller whose rates
        # need not be identical, so it reports what its locked totals imply instead (see
        # Checkout::BuyerCurrencyQuote#display_rate_for).
        rate: quote.display_rate.to_f,
        subunit_to_unit: subunit_to_unit(quote.currency),
        # The soonest expiry among the cart's locked quotes: the cart is only as fresh as its
        # earliest-lapsing amount, so reporting a later one would overstate how long the quote
        # is good for.
        expires_at: quote.stripe_fx_quote_expires_at.iso8601,
        # The server-owned split of the locked total across the cart lines, in request
        # order. The checkout renders these amounts verbatim (rather than converting each
        # line itself) so the visible lines sum to the locked total and match the amounts
        # later persisted on the purchases' presentment rows.
        line_allocations: quote.line_allocations.map do |allocation|
          {
            permalink: allocation.permalink,
            price_cents: allocation.presentment_price_cents,
            tip_cents: allocation.presentment_tip_cents,
            tax_cents: allocation.presentment_seller_tax_cents + allocation.presentment_gumroad_tax_cents,
            shipping_cents: allocation.presentment_shipping_cents,
            total_cents: allocation.presentment_total_cents,
          }
        end,
      }
    end

    def buyer_currency_charge_details(product:, item:, surcharges:)
      tax_result = surcharges.fetch(:sales_tax_result)
      full_price_cents = tax_result.price_cents.to_i
      tip_cents = item[:tip_cents]
      tip_cents = tip_cents.is_a?(String) || tip_cents.is_a?(Numeric) ? tip_cents.to_i : 0
      tip_cents = tip_cents.clamp(0, [full_price_cents, 0].max)
      full_base_price_cents = full_price_cents - tip_cents

      kind, charge_base_price_cents, charge_tip_cents, later_price_cents =
        if product.is_in_preorder_state?
          ["preorder", 0, 0, full_base_price_cents]
        elsif product.native_type == Link::NATIVE_TYPE_COMMISSION
          deposit = Commission::COMMISSION_DEPOSIT_PROPORTION
          ["commission", (full_base_price_cents * deposit).round, (tip_cents * deposit).round,
           (full_base_price_cents * (1 - deposit)).round]
        elsif ActiveModel::Type::Boolean.new.cast(item[:pay_in_installments]) && product.installment_plan.present?
          payments = product.installment_plan.calculate_installment_payment_price_cents(full_base_price_cents)
          ["installment", payments.first, tip_cents, payments.last]
        elsif product.is_recurring_billing?
          ["subscription", full_base_price_cents, tip_cents, full_base_price_cents]
        else
          return { charge_now: true, surcharges:, tip_cents:, kind: nil, later_price_cents: nil }
        end

      return { charge_now: false, surcharges: nil, tip_cents: 0, kind:, later_price_cents: } if kind == "preorder"

      charge_surcharges = calculate_surcharges(
        product,
        item[:quantity],
        charge_base_price_cents + charge_tip_cents,
        subscription_id: item[:subscription_id],
        recommended_by: item[:recommended_by],
        rate: surcharges[:rate]
      )
      return if charge_surcharges.blank?

      {
        charge_now: true,
        surcharges: charge_surcharges,
        tip_cents: charge_tip_cents,
        kind:,
        later_price_cents:,
      }
    end

    def calculate_surcharges(product, quantity, price, subscription_id: nil, recommended_by: nil, rate: :unset)
      if subscription_id.present?
        subscription = Subscription.find_by_external_id(subscription_id)
        return nil unless subscription&.original_purchase.present?
      end

      sales_tax_info = subscription&.original_purchase&.purchase_sales_tax_info
      if sales_tax_info.present?
        buyer_location = {
          postal_code: sales_tax_info.postal_code,
          country: sales_tax_info.country_code,
          ip_address: sales_tax_info.ip_address,
          state: sales_tax_info.state_code || GeoIp.lookup(sales_tax_info.ip_address)&.region_name,
        }
        buyer_vat_id = sales_tax_info.business_vat_id
        from_discover = subscription.original_purchase.was_discover_fee_charged?
      else
        buyer_location = { postal_code: params[:postal_code], country: params[:country], state: params[:state], ip_address: request.remote_ip }
        buyer_vat_id = params[:vat_id].presence

        from_discover = recommended_by.present?
      end

      shipping_destination = ShippingDestination.for_product_and_country_code(product:, country_code: params[:country])
      # Pass the product's listed currency so each rate term is converted the same way the
      # charge path does in Purchase#calculate_shipping. Calling this with the USD default and
      # converting the summed listed cents afterward is not equivalent under rounding.
      #
      # Captured once (unless the caller already has a reading from an earlier call in this
      # same request — see the `rate:` param) so it can also be bound into a buyer-currency
      # quote token (gumroad-private#1958, Greptile review on #7149): a second independent
      # `get_rate` read for the same currency can straddle an `UpdateCurrenciesWorker` cache
      # refresh and disagree with an earlier one even within a single request.
      rate = get_rate(product.price_currency_type) if rate == :unset
      rate = nil if product.price_currency_type.to_s.downcase == Currency::USD
      shipping_rate = shipping_destination&.calculate_shipping_rate(
        quantity:,
        currency_type: product.price_currency_type,
        rate:
      ) || 0

      sales_tax_result = SalesTaxCalculator.new(product:,
                                                price_cents: price,
                                                shipping_cents: shipping_rate,
                                                quantity:,
                                                buyer_location:,
                                                buyer_vat_id:,
                                                from_discover:).calculate

      { sales_tax_result:, shipping_rate:, rate: }
    end

    def available_buyer_currencies(line_items)
      products = line_items.filter_map(&:product).uniq
      unless products.present? && products.all? { Checkout::BuyerCurrencyEligibility.seller_enabled?(_1.user) }
        return [{ code: Currency::USD, label: CURRENCY_CHOICES.dig(Currency::USD, :display_format) || Currency::USD.upcase }]
      end

      codes = [Currency::USD] + CURRENCY_CHOICES.keys.map(&:to_s)
      codes.uniq.filter_map do |code|
        next unless currency_offered_for_cart?(line_items, code)

        { code:, label: (CURRENCY_CHOICES.dig(code, :display_format) || code.upcase) }
      end
    end

    def currency_offered_for_cart?(line_items, code)
      # USD is the canonical charge currency every cart can settle in, so it is always
      # offered; the gates below only decide which extra currencies join it.
      return true if code == Currency::USD

      return true if direct_listed_currency_offered_for_cart?(line_items, code)

      # A charge entirely listed in this currency uses the direct-listed lane (or stays
      # unquoted). A mixed charge instead quotes its canonical USD total, so its already-listed
      # lines must not remove a currency that the remaining lines can settle. Grouped per
      # seller inside the predicate, matching how the quote is minted and honored per charge.
      return false unless Checkout::BuyerCurrencyQuote.buyer_currency_listing_quotable?(line_items:, buyer_currency: code)

      line_items.all? do |line_item|
        product = line_item.product
        product.price_currency_type.to_s.downcase == code.to_s.downcase || currency_offered_for?(product, code)
      end
    end

    def currency_offered_for?(product, code)
      return true if code == Currency::USD
      return false if product.blank?

      buyer_currency_settleable?(
        seller: product.user,
        buyer_currency: code,
        product:,
        product_currency: product.price_currency_type
      )
    end

    def direct_listed_currency_offered_for_cart?(line_items, code)
      return false unless params[:payment_details_source] == PurchasePaymentFlow::PAYMENT_ELEMENT
      return false unless params[:payment_element_mount_currency].to_s.downcase == code.to_s.downcase
      return false if ActiveModel::Type::Boolean.new.cast(params[:save_card])

      Checkout::BuyerCurrencyEligibility.direct_listed_line_items_eligible?(line_items:, buyer_currency: code)
    end
end
