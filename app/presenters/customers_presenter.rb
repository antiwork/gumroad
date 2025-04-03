# frozen_string_literal: true

class CustomersPresenter
  attr_reader :pundit_user, :customers, :pagination, :product, :count

  def initialize(pundit_user:, customers: [], pagination: nil, product: nil, count: 0)
    @pundit_user = pundit_user
    @customers = customers
    @pagination = pagination
    @product = product
    @count = count
  end

  def customers_props
    {
      pagination:,
      product_id: product&.external_id,
      customers: customers.map { CustomerPresenter.new(purchase: _1).customer(pundit_user:) },
      count:,
      products: UserPresenter.new(user: pundit_user.seller).products_for_filter_box.map do |product|
        {
          id: product.external_id,
          name: product.name,
          variants: (product.is_physical? ? product.skus_alive_not_default : product.variant_categories_alive.first&.alive_variants || []).map do |variant|
            { id: variant.external_id, name: variant.name || "" }
          end,
        }
      end,
      currency_type: pundit_user.seller.currency_type.to_s,
      countries: Compliance::Countries.for_select.map(&:last),
      can_ping: pundit_user.seller.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME).size > 0,
      show_refund_fee_notice: pundit_user.seller.show_refund_fee_notice?,
    }
  end
end
