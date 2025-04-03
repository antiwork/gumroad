# frozen_string_literal: true

module Purchase::PingNotification
  def payload_for_ping_notification(url_parameters: nil, resource_name: nil)
    # general_permalink was being sent as "permalink' which is wrong because it's not a full url unlike the name suggests.
    # Consider it deprecated; it's removed from the ping docs and replaced with product_permalink, which is a url.
    payload = {
      seller_id: ObfuscateIds.encrypt(seller.id),
      product_id: ObfuscateIds.encrypt(link.id),
      product_name: link.name,
      permalink: link.general_permalink,
      product_permalink: link.long_url,
      short_product_id: link.unique_permalink,
      email:,
      price: price_cents,
      gumroad_fee: fee_cents,
      currency: link.price_currency_type,
      quantity:,
      discover_fee_charged: was_discover_fee_charged?,
      can_contact: can_contact?,
      referrer:,
      card: {
        visual: card_visual,
        type: card_type,

        # legacy params
        bin: nil,
        expiry_month: nil,
        expiry_year: nil
      }
    }

    payload[:order_number] = external_id_numeric
    payload[:sale_id] = ObfuscateIds.encrypt(id)
    payload[:sale_timestamp] = created_at.as_json
    payload[:full_name] = full_name if full_name.present?
    payload[:purchaser_id] = purchaser.external_id if purchaser
    payload[:subscription_id] = subscription.external_id if subscription.present?
    payload[:affiliate_credit_amount_cents] = affiliate_credit_cents if affiliate_credit.present?
    payload[:url_params] = url_parameters if url_parameters.present?
    payload[:variants] = variant_names_hash if variant_names_hash.present?
    payload[:offer_code] = offer_code.code if offer_code.present?
    payload[:test] = true if purchaser == seller
    payload[:is_recurring_charge] = true if is_recurring_subscription_charge
    payload[:is_preorder_authorization] = true if is_preorder_authorization
    payload.merge!(shipping_information) if shipping_information.present?
    payload[:shipping_information] = shipping_information if shipping_information.present?
    custom_fields.each { |field| payload[field[:name]] = field[:value] }
    custom_fields_payload = if custom_fields.present?
      custom_fields.pluck(:name, :value).to_h
    elsif subscription&.custom_fields.present?
      subscription.custom_fields.pluck(:name, :value).to_h
    end
    payload[:custom_fields] = custom_fields_payload if custom_fields_payload.present?
    payload[:license_key] = license_key if license_key.present?
    payload[:is_multiseat_license] = is_multiseat_license? if license_key.present? && subscription.present?
    payload[:ip_country] = ip_country if ip_country.present?
    payload[:shipping_rate] = shipping_cents if link.is_physical
    payload[:recurrence] = subscription.recurrence if subscription.present?
    payload[:affiliate] = affiliate.affiliate_user.form_email if affiliate.present?
    payload[:is_gift_receiver_purchase] = is_gift_receiver_purchase?

    if is_gift_receiver_purchase?
      payload[:gift_price] = gift.gifter_purchase.price_cents
      payload[:gifter_email] = gift.gifter_purchase.email
    end

    if link.skus_enabled || link.is_physical
      # Hack for accutrak (accuhack?)
      payload[:sku_id] = sku_custom_name_or_external_id
      # Hack for printful (hackful?)
      payload[:original_sku_id] = sku.external_id if sku.try(:custom_sku).present?
    end

    payload[:refunded] = stripe_refunded.present?
    payload[:resource_name] = resource_name if resource_name.present?

    payload[:disputed] = chargedback?
    payload[:dispute_won] = chargeback_reversed?

    Rails.logger.info("payload_for_ping_notification #{payload.inspect}")

    payload
  end
end
