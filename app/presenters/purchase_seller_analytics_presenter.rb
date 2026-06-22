# frozen_string_literal: true

class PurchaseSellerAnalyticsPresenter
  include CurrencyHelper

  def initialize(purchase)
    @purchase = purchase
  end

  def props
    return nil unless purchase

    product = purchase.link
    return nil unless product

    analytics = product.analytics_data
    return nil unless analytics[:facebook_pixel_id] || analytics[:google_analytics_id] || analytics[:tiktok_pixel_id]

    currency_type = purchase.displayed_price_currency_type.to_s
    {
      seller_id: product.user.external_id,
      analytics:,
      purchase_event: {
        permalink: product.unique_permalink,
        purchase_external_id: purchase.external_id,
        product_name: product.name,
        value: Money.new(purchase.displayed_price_cents, currency_type).cents,
        currency: currency_type,
        quantity: purchase.quantity,
        tax: Money.new(purchase.seller_taxes_in_purchase_currency, currency_type).format(no_cents_if_whole: true, symbol: false),
        buyer_currency_display: buyer_currency_display_props(product:, price_cents: purchase.displayed_price_cents, ip: purchase.ip_address),
      }
    }
  end

  private
    attr_reader :purchase
end
