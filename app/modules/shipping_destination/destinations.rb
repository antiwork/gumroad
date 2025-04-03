# frozen_string_literal: true

module ShippingDestination::Destinations
  # constant referring to all other countries
  ELSEWHERE = "ELSEWHERE"
  # constants for virtual countries
  EUROPE = "EUROPE"
  ASIA = "ASIA"
  NORTH_AMERICA = "NORTH AMERICA"
  VIRTUAL_COUNTRY_CODES = [EUROPE, ASIA, NORTH_AMERICA].freeze

  def self.shipping_countries
    first_countries = {
      "US" => "United States",
      ASIA => ASIA.titleize,
      EUROPE => EUROPE.titleize,
      NORTH_AMERICA => NORTH_AMERICA.titleize,
      ELSEWHERE => ELSEWHERE.titleize
    }

    first_countries.merge!(Compliance::Countries.for_select.to_h)
  end

  def self.europe_shipping_countries
    @_europe_shipping_countries ||=
      ISO3166::Country.all
        .select { |country| country.continent == "Europe" }
        .reject { |country| Compliance::Countries.blocked?(country.alpha2) || Compliance::Countries.risk_physical_blocked?(country.alpha2) }
        .map { |country| [country.alpha2, country.common_name] }
        .sort_by { |pair| pair.last }
        .to_h
  end

  def self.asia_shipping_countries
    @_asia_shipping_countries ||=
      ISO3166::Country.all
        .select { |country| country.continent == "Asia" }
        .reject { |country| Compliance::Countries.blocked?(country.alpha2) || Compliance::Countries.risk_physical_blocked?(country.alpha2) }
        .map { |country| [country.alpha2, country.common_name] }
        .sort_by { |pair| pair.last }
        .to_h
  end

  def self.north_america_shipping_countries
    @_north_america_shipping_countries ||=
      ISO3166::Country.all
        .select { |country| country.continent == "North America" }
        .reject { |country| Compliance::Countries.blocked?(country.alpha2) || Compliance::Countries.risk_physical_blocked?(country.alpha2) }
        .map { |country| [country.alpha2, country.common_name] }
        .sort_by { |pair| pair.last }
        .to_h
  end

  def self.virtual_countries_for_country_code(country_code)
    virtual_countries = []
    virtual_countries << ASIA if asia_shipping_countries.include?(country_code)
    virtual_countries << EUROPE if europe_shipping_countries.include?(country_code)
    virtual_countries << NORTH_AMERICA if north_america_shipping_countries.include?(country_code)
    virtual_countries
  end
end
