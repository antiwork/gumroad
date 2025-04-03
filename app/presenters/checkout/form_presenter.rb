# frozen_string_literal: true

class Checkout::FormPresenter
  include CheckoutDashboardHelper

  attr_reader :pundit_user

  def initialize(pundit_user:)
    @pundit_user = pundit_user
  end

  def form_props
    seller = pundit_user.seller
    products = seller.products.visible.order(created_at: :desc).to_a
    cart_product = products.first
    {
      pages:,
      user: {
        display_offer_code_field: seller.display_offer_code_field?,
        recommendation_type: seller.recommendation_type,
        tipping_enabled: seller.tipping_enabled?,
      },
      cart_item: cart_product.present? ? CheckoutPresenter.new(logged_in_user: nil, ip: nil).checkout_product(cart_product, cart_product.cart_item({}), {}).merge({ quantity: 1, url_parameters: {}, referrer: "" }) : nil,
      custom_fields: seller.custom_fields.not_is_post_purchase.map(&:as_json),
      card_product: cart_product.present? ? ProductPresenter.card_for_web(product: cart_product) : nil,
      products: products.map { |product| { id: product.external_id, name: product.name, archived: product.archived? } },
    }
  end
end
