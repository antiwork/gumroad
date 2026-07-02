# frozen_string_literal: true

module Order::ResponseHelpers
  include CurrencyHelper

  private
    # Buyer-presentment purchases stay in_progress until Stripe settlement data arrives, so
    # the checkout/confirm response must withhold content and receipt affordances until
    # FinalizeBuyerPresentmentChargeJob completes the purchase.
    def purchase_pending_processor_settlement_response(purchase)
      purchase.purchase_response.tap do |response|
        response[:content_url] = nil
        response[:redirect_token] = nil
        response[:url_redirect_external_id] = nil
        response[:should_show_receipt] = false
        response[:show_view_content_button_on_product_page] = false
        response[:has_third_party_analytics] = false
        response[:bundle_products]&.each { _1[:content_url] = nil }
      end
    end

    def error_response(error_message, purchase: nil)
      card_country = purchase&.card_country
      card_country = "CN" if card_country == "C2" # PayPal (wrongly) returns CN2 for China users transacting with USD

      {
        success: false,
        error_message:,
        permalink: purchase&.link&.unique_permalink,
        name: purchase&.link&.name,
        formatted_price: formatted_price(Currency::USD, purchase&.total_transaction_cents_usd),
        error_code: purchase&.error_code,
        is_tax_mismatch: purchase&.error_code == PurchaseErrorCode::TAX_VALIDATION_FAILED,
        card_country: (ISO3166::Country[card_country]&.common_name if card_country.present?),
        ip_country: purchase&.ip_country,
        updated_product: purchase.present? ? CheckoutPresenter.new(logged_in_user: nil, ip: purchase.ip_address).checkout_product(purchase.link, purchase.link.cart_item({ rent: purchase.is_rental, option: purchase.variant_attributes.first&.external_id, recurrence: purchase.price&.recurrence, price: purchase.customizable_price? ? purchase.displayed_price_cents : nil }), { recommended_by: purchase.recommended_by.presence }) : nil,
      }
    end
end
