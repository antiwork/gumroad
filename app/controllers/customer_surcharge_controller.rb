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
      surcharges = calculate_surcharges(product, item[:quantity], item[:price].to_d.to_i, subscription_id: item[:subscription_id], recommended_by: item[:recommended_by])
      unless surcharges
        all_lines_quotable = false
        next
      end
      tax_result = surcharges[:sales_tax_result]
      vat_id_valid = tax_result.business_vat_status == :valid
      has_vat_id_input ||= tax_result.to_hash[:has_vat_id_input]
      shipping_usd_cents = get_usd_cents(product.price_currency_type, surcharges[:shipping_rate])
      shipping_rate += shipping_usd_cents
      tax_cents = tax_result.tax_cents
      if tax_cents > 0
        tax_rate += tax_cents
      end
      subtotal += tax_result.price_cents
      quote_line_items << Checkout::BuyerCurrencyQuote::LineItem.from_surcharge(
        permalink: item[:permalink].to_s,
        product:,
        tax_result:,
        tip_cents: item[:tip_cents],
        shipping_usd_cents:
      )
    end

    render json: {
      vat_id_valid:,
      has_vat_id_input:,
      shipping_rate_cents: shipping_rate,
      tax_cents: tax_rate.round.to_i,
      tax_included_cents: tax_included_rate.round.to_i,
      subtotal: subtotal.round.to_i,
      buyer_currency_quote: buyer_currency_quote_props(
        line_items: all_lines_quotable ? quote_line_items : nil,
        # Sum the per-line integer totals rather than rounding the fractional running
        # totals once: two lines with fractional taxes (0.4 + 0.4) round to 0 per line
        # but 1 when summed first, and a quote whose lines don't reconcile to its total
        # is refused. The per-line integers are also what the purchases carry at charge
        # time, so this is the total the quote verification will see.
        canonical_total_cents: quote_line_items.sum(&:canonical_total_cents)
      )
    }
  end

  private
    def buyer_currency_quote_props(line_items:, canonical_total_cents:)
      return if line_items.nil?

      quote = Checkout::BuyerCurrencyQuote.create(
        line_items:,
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
