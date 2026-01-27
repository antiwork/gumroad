# frozen_string_literal: true

class Admin::PurchasePresenter
  attr_reader :purchase

  def initialize(purchase)
    @purchase = purchase
  end

  def list_props
    {
      external_id: purchase.external_id,
      formatted_display_price: purchase.formatted_display_price,
      formatted_gumroad_tax_amount: purchase.gumroad_tax_cents > 0 ? purchase.formatted_gumroad_tax_amount : nil,
      gumroad_responsible_for_tax: purchase.gumroad_responsible_for_tax?,
      product: { external_id: purchase.link.external_id, name: purchase.link.name, long_url: purchase.link.long_url },
      variants_list: purchase.variants_list,
      refund_policy: purchase.purchase_refund_policy.present? ? {
        title: purchase.purchase_refund_policy.title,
        current_refund_policy: purchase.purchase_refund_policy&.different_than_product_refund_policy? ? purchase.purchase_refund_policy.product_refund_policy&.title || "None" : nil
      }
      : nil,
      seller: { email: purchase.seller.email, support_email: purchase.seller.support_email },
      email: purchase.email,
      created_at: purchase.created_at,
      purchase_state: purchase.purchase_state.capitalize,
      stripe_refunded: purchase.stripe_refunded?,
      stripe_partially_refunded: purchase.stripe_partially_refunded?,
      chargedback: purchase.chargedback?,
      chargeback_reversed: purchase.chargeback_reversed?,
      error_code: purchase.failed? ? purchase.formatted_error_code : nil,
      last_chargebacked_purchase: purchase.find_past_chargebacked_purchases.first&.external_id,
    }
  end

  def props
    base_props = list_props
    email_info = CustomerEmailInfo.where(purchase: purchase, email_name: purchase.is_preorder_authorization ? "preorder_receipt" : "receipt").last
    email_info_text = email_info.try(:state).try(:capitalize)
    email_info_text += " (on #{email_info.delivered_at})" if email_info.try(:delivered?)
    email_info_text += " (on #{email_info.opened_at})" if email_info.try(:opened?)
    base_props[:refund_policy]&.merge!({
                                         fine_print: purchase.purchase_refund_policy.fine_print.presence || purchase.link.product_refund_policy&.fine_print,
                                         max_refund_period_in_days: purchase.purchase_refund_policy.max_refund_period_in_days
                                       })
    base_props.merge({
                       updated_at: purchase.updated_at,
                       deleted_at: purchase.deleted_at,
                       external_id: purchase.external_id,
                       merchant_account: purchase.merchant_account.present? ? {
                         external_id: purchase.merchant_account.external_id,
                         charge_processor_id: purchase.merchant_account.charge_processor_id&.capitalize,
                         holder_of_funds: purchase.merchant_account.holder_of_funds.capitalize,
                       } : nil,
                       fee_cents: purchase.fee_cents,
                       tip: purchase.tip&.value_usd_cents,
                       formatted_seller_tax_amount: purchase.tax_cents > 0 ? purchase.formatted_seller_tax_amount : nil,
                       gumroad_tax_cents: purchase.gumroad_tax_cents,
                       formatted_shipping_amount: purchase.shipping_cents > 0 ? purchase.formatted_shipping_amount : nil,
                       formatted_affiliate_credit_amount: purchase.affiliate.present? ? purchase.formatted_affiliate_credit_amount : nil,
                       formatted_total_transaction_amount: purchase.formatted_total_transaction_amount,
                       charge_processor_id: purchase.charge_processor_id&.capitalize,
                       stripe_transaction: purchase.stripe_transaction_id ? {
                         id: purchase.stripe_transaction_id,
                         search_url: ChargeProcessor.transaction_url_for_admin(purchase.charge_processor_id, purchase.stripe_transaction_id, purchase.charged_using_gumroad_merchant_account?),
                       } : nil,
                       external_id_numeric: purchase.external_id_numeric,
                       quantity: purchase.quantity,
                       refunds: purchase.refunds.map do |refund|
                         {
                           user: refund.user ? { external_id: refund.user.external_id, name: refund.user.name } : nil,
                           status: refund.status.capitalize,
                           created_at: refund.created_at,
                         }
                       end,
                       card: purchase.card_type.present? && purchase.card_visual.present? ? {
                         type: purchase.card_type.upcase,
                         visual: purchase.card_visual.delete("*").delete(" "),
                         country: purchase.card_country,
                         fingerprint_search_url: purchase.stripe_charge_processor? ? StripeChargeProcessor.fingerprint_search_url(purchase.stripe_fingerprint) : nil,
                       } : nil,
                       ip_address: purchase.ip_address,
                       ip_country: purchase.ip_country,
                       is_preorder_authorization: purchase.is_preorder_authorization,
                       subscription: purchase.subscription ? {
                         id: purchase.subscription.id,
                         external_id: purchase.subscription.external_id,
                         cancelled_at: purchase.subscription.cancelled_at,
                         cancelled_by_buyer: purchase.subscription.cancelled_by_buyer,
                         ended_at: purchase.subscription.ended_at,
                         failed_at: purchase.subscription.failed_at,
                       } : nil,
                       email_info: email_info_text,
                       is_bundle_purchase: purchase.is_bundle_purchase,
                       product_purchases: purchase.product_purchases.map do |product_purchase|
                         {
                           product: { name: product_purchase.link.name },
                           url_redirect: product_purchase.url_redirect ? url_redirect_props(product_purchase.url_redirect) : nil,
                         }
                       end,
                       url_redirect: purchase.url_redirect ? url_redirect_props(purchase.url_redirect) : nil,
                       offer_code: purchase.offer_code ? {
                         code: purchase.offer_code.code,
                         displayed_amount_off: purchase.offer_code.displayed_amount_off(purchase.link.price_currency_type, with_symbol: true),
                       } : nil,
                       street_address: purchase.street_address,
                       full_name: purchase.full_name,
                       city: purchase.city,
                       state: purchase.state,
                       zip_code: purchase.zip_code,
                       country: purchase.country,
                       is_gift_sender_purchase: purchase.is_gift_sender_purchase,
                       custom_fields: purchase.custom_fields,
                       license: purchase.license.present? ? { serial: purchase.license.serial } : nil,
                       affiliate_email: purchase.affiliate.present? ? purchase.affiliate.affiliate_user.form_email : nil,
                       can_contact: purchase.can_contact?,
                       gift: purchase.is_gift_sender_purchase ?
                               { is_sender_purchase: true, other_purchase_external_id: purchase.gift.giftee_purchase&.external_id, other_email: purchase.giftee_email, note: purchase.gift_note } :
                               purchase.is_gift_receiver_purchase ?
                                 { is_sender_purchase: false, other_purchase_external_id: purchase.gift.gifter_purchase&.external_id, other_email: purchase.gifter_email, note: purchase.gift_note } :
                                 nil,
                       successful: purchase.successful?,
                       can_force_update: purchase.can_force_update?,
                       failed: purchase.failed?,
                       stripe_fingerprint: purchase.stripe_fingerprint,
                       is_free_trial_purchase: purchase.is_free_trial_purchase?,
                       buyer_blocked: purchase.buyer_blocked?,
                       is_deleted_by_buyer: purchase.is_deleted_by_buyer?,
                       comments_count: purchase.comments.count,
                     })
  end

  private
    def url_redirect_props(url_redirect)
      { download_page_url: url_redirect.download_page_url, uses: url_redirect.uses }
    end
end
