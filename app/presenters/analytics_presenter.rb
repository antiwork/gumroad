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
      # The share of a typical day's revenue this seller has historically booked by
      # now, or null when recent history is too thin. Used to weight the projected
      # end-of-day total by when this seller's sales actually happen instead of
      # assuming a uniform run rate. Computed once at page render — the projection
      # only refreshes when the page data does, so a point-in-time value is enough.
      expected_sales_fraction_of_day: CreatorAnalytics::HourlySalesCurve.new(seller:).expected_fraction_of_day,
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
