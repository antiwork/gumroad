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

    # CreateService finds the product through the column's case-insensitive collation, so the
    # submitted permalink can differ in case from unique_permalink.
    def line_item_uid_for(purchase)
      permalink = purchase.link.unique_permalink
      line_item = params[:line_items].find do |candidate|
        candidate[:permalink].to_s.downcase == permalink.to_s.downcase &&
          (candidate[:variants].blank? || purchase.variant_attributes.first&.external_id == candidate[:variants]&.first)
      end
      line_item&.dig(:uid) || cart_item_uid_for(purchase)
    end

    # Mirrors the browser's getCartItemUid, so a purchase that matches no submitted line item still
    # gets a response key instead of a nil one.
    def cart_item_uid_for(purchase)
      "#{purchase.link.unique_permalink} #{purchase.variant_attributes.first&.external_id}"
    end

    def error_response(error_message, purchase: nil, guest: false)
      card_country = purchase&.card_country
      card_country = "CN" if card_country == "C2" # PayPal (wrongly) returns CN2 for China users transacting with USD
      # That line was priced with the discount it was refused, so its total is not what the buyer would pay.
      new_customer_offer_code_refused = purchase&.new_customer_offer_code_refused?

      response = {
        success: false,
        error_message:,
        permalink: purchase&.link&.unique_permalink,
        name: purchase&.link&.name,
        formatted_price: (formatted_price(Currency::USD, purchase&.total_transaction_cents_usd) unless new_customer_offer_code_refused),
        error_code: purchase&.error_code,
        is_tax_mismatch: purchase&.error_code == PurchaseErrorCode::TAX_VALIDATION_FAILED,
        card_country: (ISO3166::Country[card_country]&.common_name if card_country.present?),
        ip_country: purchase&.ip_country,
        updated_product: purchase.present? ? updated_product(purchase) : nil,
      }
      # `guest` is whether the request is unauthenticated, which is not the same as the purchase
      # lacking a purchaser. Only sent when it applies, so every other failure keeps its response
      # shape byte for byte.
      response[:owner_sign_in_remedy] = true if guest && purchase&.owner_sign_in_lifts_product_block?
      response[:new_customer_offer_code_refused] = true if new_customer_offer_code_refused
      response
    end

    # The retry re-applies the line's discounts, so a pay-what-you-want line must come back at the
    # buyer's undiscounted unit price. `cart_item` raises it to the current minimum.
    def updated_product(purchase)
      price = purchase.customizable_price? ? (purchase.pre_discount_unit_price_cents || purchase.displayed_price_cents) : nil
      cart_item = purchase.link.cart_item({ rent: purchase.is_rental, option: purchase.variant_attributes.first&.external_id, recurrence: purchase.price&.recurrence, price: })
      CheckoutPresenter.new(logged_in_user: nil, ip: purchase.ip_address).checkout_product(purchase.link, cart_item, { recommended_by: purchase.recommended_by.presence })
    end
end
