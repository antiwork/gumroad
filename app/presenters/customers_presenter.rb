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
    user_presenter = UserPresenter.new(user: pundit_user.seller)
    {
      pagination:,
      product_id: product&.external_id,
      customers: customers.map { CustomerPresenter.new(purchase: _1).customer(pundit_user:) },
      count:,
      products: user_presenter.products_for_filter_box.map do |product|
        {
          id: product.external_id,
          permalink: product.unique_permalink,
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
      license_uses_filter_enabled: Feature.active?(:license_uses_sales_filter, pundit_user.seller),
      can_send_emails: user_presenter.audience_types.include?(:customers),
    }
  end
end
