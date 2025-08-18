# frozen_string_literal: true

class Purchase::CreateBundleProductPurchaseService
  def initialize(purchase, bundle_product)
    @purchase = purchase
    @bundle_product = bundle_product
  end

  def perform
    product_purchase = Purchase.create!(
      link: @bundle_product.product,
      seller: @purchase.seller,
      purchaser: @purchase.purchaser,
      price_cents: 0,
      total_transaction_cents: 0,
      displayed_price_cents: 0,
      gumroad_tax_cents: 0,
      shipping_cents: 0,
      fee_cents: 0,
      email: @purchase.email,
      full_name: @purchase.full_name,
      street_address: @purchase.street_address,
      country: @purchase.country,
      state: @purchase.state,
      zip_code: @purchase.zip_code,
      city: @purchase.city,
      ip_address: @purchase.ip_address,
      ip_state: @purchase.ip_state,
      ip_country: @purchase.ip_country,
      browser_guid: @purchase.browser_guid,
      referrer: @purchase.referrer,
      was_product_recommended: @purchase.was_product_recommended,
      variant_attributes: @bundle_product.variant.present? ? [@bundle_product.variant] : [],
      quantity: @bundle_product.quantity * @purchase.quantity,
      is_bundle_product_purchase: true,
      is_gift_sender_purchase: @purchase.is_gift_sender_purchase,
      is_gift_receiver_purchase: @purchase.is_gift_receiver_purchase
    )
    # Custom fields for bundle products are temporarily saved on the bundle purchase until we can assign them
    # to their respective purchase records.
    @purchase.purchase_custom_fields.where(bundle_product: @bundle_product).each { _1.update!(purchase: product_purchase, bundle_product: nil) }
    BundleProductPurchase.create!(bundle_purchase: @purchase, product_purchase:)
    product_purchase.update_balance_and_mark_successful!

    Purchase::AssociateBundleProductLevelGiftService
      .new(bundle_purchase: @purchase, bundle_product: @bundle_product)
      .perform
  end
end
