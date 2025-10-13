# frozen_string_literal: true

class ChurnPresenter
  def initialize(seller:)
    @seller = seller
  end

  def page_props
    {
      has_subscription_products: has_subscription_products?
    }
  end

  private
    attr_reader :seller

    def has_subscription_products?
      seller.products.alive.is_recurring_billing.exists?
    end
end
