# frozen_string_literal: true

class AnalyticsPresenter
  def initialize(seller:)
    @seller = seller
  end

  def page_props
    {
      products: seller.products_for_creator_analytics.map { product_props(_1) },
      country_codes: Compliance::Countries.mapping.invert,
      state_names: STATES_SUPPORTED_BY_ANALYTICS.map { |state_code| Compliance::Countries::USA.subdivisions[state_code]&.name || "Other" }
    }
  end

  private
    attr_reader :seller

    def product_props(product)
      { id: product.external_id, alive: product.alive?, unique_permalink: product.unique_permalink, name: product.name }
    end
end
