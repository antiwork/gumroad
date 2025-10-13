# frozen_string_literal: true

class ChurnPresenter
  def initialize(seller:)
    @seller = seller
  end

  def page_props
    {
      products: subscription_products,
      has_subscription_products: subscription_products.any?
    }
  end

  private
    attr_reader :seller

    def subscription_products
      @subscription_products ||= seller.products
        .alive
        .is_recurring_billing
        .map { |product| product_props(product) }
    end

    def product_props(product)
      {
        id: product.external_id,
        name: product.name,
        unique_permalink: product.unique_permalink,
        alive: product.alive?
      }
    end
end
