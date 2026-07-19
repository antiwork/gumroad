# frozen_string_literal: true

class AnalyticsPresenter
  def initialize(seller:)
    @seller = seller
  end

  def page_props
    {
      products: seller.products_for_creator_analytics.map { product_props(_1) },
      # IANA time zone identifier (e.g. "America/Los_Angeles") used by the sales chart
      # to compute how much of the seller's current day has elapsed when projecting
      # today's end-of-day sales total.
      seller_time_zone: seller.timezone_id,
      country_codes: Compliance::Countries.alpha2_by_name,
      state_names: STATES_SUPPORTED_BY_ANALYTICS.map { |state_code| Compliance::Countries::USA.subdivisions[state_code]&.name || "Other" }
    }
  end

  private
    attr_reader :seller

    def product_props(product)
      { id: product.external_id, alive: product.alive?, unique_permalink: product.unique_permalink, name: product.name }
    end
end
