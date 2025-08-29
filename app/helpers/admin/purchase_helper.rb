# frozen_string_literal: true

module Admin::PurchaseHelper
  def purchase_states(purchase)
    [
      purchase.purchase_state.capitalize,
      ("(refunded)" if purchase.stripe_refunded?),
      ("(partially refunded)" if purchase.stripe_partially_refunded?),
      ("(chargeback)" if purchase.chargedback_not_reversed?),
      ("(chargeback reversed)" if purchase.chargeback_reversed?),
      purchase_error_code(purchase),
    ].compact
  end

  def purchase_error_code(purchase)
    return unless purchase.failed?

    formatted_error_code = purchase.formatted_error_code

    last_chargebacked_purchase = purchase.find_past_chargebacked_purchases.first

    if last_chargebacked_purchase.present?
      "(#{link_to(formatted_error_code, admin_purchase_path(last_chargebacked_purchase))})".html_safe
    else
      "(#{formatted_error_code})"
    end
  end
end
