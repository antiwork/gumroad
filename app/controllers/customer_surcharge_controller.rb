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
    quoted_products = []
    products.each do |item|
      product = Link.find_by_unique_permalink(item[:permalink])
      next unless product
      quoted_products << product
      surcharges = calculate_surcharges(product, item[:quantity], item[:price].to_d.to_i, subscription_id: item[:subscription_id], recommended_by: item[:recommended_by])
      next unless surcharges
      tax_result = surcharges[:sales_tax_result]
      vat_id_valid = tax_result.business_vat_status == :valid
      has_vat_id_input ||= tax_result.to_hash[:has_vat_id_input]
      shipping_rate += get_usd_cents(product.price_currency_type, surcharges[:shipping_rate])
      tax_cents = tax_result.tax_cents
      if tax_cents > 0
        tax_rate += tax_cents
      end
      subtotal += tax_result.price_cents
    end

    render json: {
      vat_id_valid:,
      has_vat_id_input:,
      shipping_rate_cents: shipping_rate,
      tax_cents: tax_rate.round.to_i,
      tax_included_cents: tax_included_rate.round.to_i,
      subtotal: subtotal.round.to_i,
      buyer_currency_quote: buyer_currency_quote_props(
        products: quoted_products,
        canonical_total_cents: subtotal + tax_rate + shipping_rate
      )
    }
  end

  private
    def buyer_currency_quote_props(products:, canonical_total_cents:)
      quote = Checkout::BuyerCurrencyQuote.create(
        products:,
        canonical_total_cents: canonical_total_cents.round.to_i,
        ip: request.remote_ip
      )
      return if quote.blank?

      {
        token: quote.token,
        currency: quote.currency,
        canonical_total_cents: quote.canonical_total_cents,
        presentment_total_cents: quote.presentment_total_cents,
        # Exact minor-unit rate from the locked quote, not a ratio of already-rounded
        # totals — client-side line conversions inherit the ratio's rounding error.
        rate: (BigDecimal(subunit_to_unit(quote.currency)) / (subunit_to_unit(Currency::USD) * quote.fx_rate)).to_f,
        subunit_to_unit: subunit_to_unit(quote.currency),
        expires_at: quote.stripe_fx_quote_expires_at.iso8601,
      }
    end

    def calculate_surcharges(product, quantity, price, subscription_id: nil, recommended_by: nil)
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
      shipping_rate = shipping_destination&.calculate_shipping_rate(quantity:) || 0

      sales_tax_result = SalesTaxCalculator.new(product:,
                                                price_cents: price,
                                                shipping_cents: shipping_rate,
                                                quantity:,
                                                buyer_location:,
                                                buyer_vat_id:,
                                                from_discover:).calculate

      { sales_tax_result:, shipping_rate: }
    end
end
