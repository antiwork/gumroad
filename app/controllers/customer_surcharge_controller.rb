# frozen_string_literal: true

class CustomerSurchargeController < ApplicationController
  include CurrencyHelper

  def calculate_all
    products_params = params.require(:products)

    # PERF: Bulk fetch all Links and Subscriptions to avoid N+1 queries in the loop
    permalinks = products_params.map { _1[:permalink] }.uniq
    links_by_permalink = Link.where(unique_permalink: permalinks).index_by(&:unique_permalink)

    subscription_ids = products_params.map { _1[:subscription_id] }.compact.uniq
    subscriptions_by_external_id = if subscription_ids.any?
      Subscription.includes(original_purchase: :purchase_sales_tax_info)
                  .where(external_id: subscription_ids)
                  .index_by(&:external_id)
    else
      {}
    end

    vat_id_valid = false
    has_vat_id_input = false
    shipping_rate = 0
    tax_rate = 0
    tax_included_rate = 0
    subtotal = 0

    products_params.each do |item|
      product = links_by_permalink[item[:permalink]]
      next unless product

      subscription = subscriptions_by_external_id[item[:subscription_id]]
      surcharges = calculate_surcharges(product, item[:quantity], item[:price].to_d.to_i, subscription: subscription, recommended_by: item[:recommended_by])
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
      vat_id_valid: vat_id_valid,
      has_vat_id_input: has_vat_id_input,
      shipping_rate_cents: shipping_rate,
      tax_cents: tax_rate.round.to_i,
      tax_included_cents: tax_included_rate.round.to_i,
      subtotal: subtotal.round.to_i
    }
  end

  private

  # Changed signature to accept the subscription object directly
  def calculate_surcharges(product, quantity, price, subscription: nil, recommended_by: nil)
    if subscription.present?
      return nil unless subscription.original_purchase.present?
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

    shipping_destination = ShippingDestination.for_product_and_country_code(product: product, country_code: params[:country])
    shipping_rate = shipping_destination&.calculate_shipping_rate(quantity: quantity) || 0

    sales_tax_result = SalesTaxCalculator.new(
      product: product,
      price_cents: price,
      shipping_cents: shipping_rate,
      quantity: quantity,
      buyer_location: buyer_location,
      buyer_vat_id: buyer_vat_id,
      from_discover: from_discover
    ).calculate

    { sales_tax_result: sales_tax_result, shipping_rate: shipping_rate }
  end
end
