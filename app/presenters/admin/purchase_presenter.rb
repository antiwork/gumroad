# frozen_string_literal: true

class Admin::PurchasePresenter
  attr_reader :purchase

  def initialize(purchase)
    @purchase = purchase
  end

  def list_props
    {
      id: purchase.id,
      formatted_display_price: purchase.formatted_display_price,
      formatted_gumroad_tax_amount: purchase.formatted_gumroad_tax_amount,
      gumroad_responsible_for_tax: purchase.gumroad_responsible_for_tax?,
      product: { id: purchase.link.id, name: purchase.link.name, long_url: purchase.link.long_url },
      variants_list: purchase.variants_list,
      purchase_refund_policy: purchase.purchase_refund_policy&.title,
      product_refund_policy: purchase.purchase_refund_policy&.different_than_product_refund_policy? ? purchase.purchase_refund_policy.product_refund_policy&.title || "None" : nil,
      seller: { email: purchase.seller.email, support_email: purchase.seller.support_email },
      email: purchase.email,
      created_at: purchase.created_at,
      purchase_state: purchase.purchase_state.capitalize,
      stripe_refunded: purchase.stripe_refunded?,
      stripe_partially_refunded: purchase.stripe_partially_refunded?,
      chargedback: purchase.chargedback?,
      chargeback_reversed: purchase.chargeback_reversed?,
      error_code: purchase.failed? ? purchase.formatted_error_code : nil,
      last_chargebacked_purchase: purchase.find_past_chargebacked_purchases.first&.id,
    }
  end
end
