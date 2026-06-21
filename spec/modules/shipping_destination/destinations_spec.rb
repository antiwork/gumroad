# frozen_string_literal: true

require "spec_helper"

# These hashes are derived from the production module rather than hard-coded
# so the spec can't drift when BLOCKED_COUNTRY_CODES / RISK_PHYSICAL_BLOCKED_COUNTRY_CODES
# change. The previous hand-curated lists were a maintenance footgun that
# broke on every sanctions audit.
describe ShippingDestination::Destinations do
  describe ".shipping_countries" do
    it "returns the expected shipping countries" do
      expect(ShippingDestination::Destinations.shipping_countries).to eq(shipping_countries_expected)
    end

    it "includes the US, ASIA, EUROPE, NORTH AMERICA, and ELSEWHERE virtual entries" do
      expect(ShippingDestination::Destinations.shipping_countries).to include(
        "US" => "United States",
        "ASIA" => "Asia",
        "EUROPE" => "Europe",
        "NORTH AMERICA" => "North America",
        "ELSEWHERE" => "Elsewhere"
      )
    end

    it "excludes countries that are blocked or risk-physical-blocked" do
      expect(ShippingDestination::Destinations.shipping_countries.keys).not_to include("CU", "IR", "KP")
    end
  end

  describe ".europe_shipping_countries" do
    it "returns the expected Europe countries mapping" do
      expect(ShippingDestination::Destinations.europe_shipping_countries).to eq(europe_shipping_countries_expected)
    end
  end

  describe ".asia_shipping_countries" do
    it "returns the expected Asia countries mapping" do
      expect(ShippingDestination::Destinations.asia_shipping_countries).to eq(asia_shipping_countries_expected)
    end
  end

  describe ".north_america_shipping_countries" do
    it "returns the expected North America countries mapping" do
      expect(ShippingDestination::Destinations.north_america_shipping_countries).to eq(north_america_shipping_countries_expected)
    end
  end

  private
    def shipping_countries_expected
      first_countries = {
        "US" => "United States",
        ShippingDestination::Destinations::ASIA => "Asia",
        ShippingDestination::Destinations::EUROPE => "Europe",
        ShippingDestination::Destinations::NORTH_AMERICA => "North America",
        ShippingDestination::Destinations::ELSEWHERE => "Elsewhere"
      }
      first_countries.merge!(
        Compliance::Countries.for_select.reject { |c| Compliance::Countries.blocked?(c[0]) }.to_h
      )
    end

    def continent_expected(continent_name)
      ISO3166::Country.all
        .select { |c| c.continent == continent_name }
        .reject { |c| Compliance::Countries.blocked?(c.alpha2) || Compliance::Countries.risk_physical_blocked?(c.alpha2) }
        .map { |c| [c.alpha2, c.common_name] }
        .sort_by { |pair| pair.last }
        .to_h
    end

    def europe_shipping_countries_expected
      continent_expected("Europe")
    end

    def asia_shipping_countries_expected
      continent_expected("Asia")
    end

    def north_america_shipping_countries_expected
      continent_expected("North America")
    end
end
