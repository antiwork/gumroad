# frozen_string_literal: true

module GeoIp
  class Result
    attr_reader :country_name, :country_code, :region_name, :city_name, :postal_code, :latitude, :longitude

    def initialize(country_name:, country_code:, region_name:, city_name:, postal_code:, latitude:, longitude:)
      @country_name = country_name
      @country_code = country_code
      @region_name = region_name
      @city_name = city_name
      @postal_code = postal_code
      @latitude = latitude
      @longitude = longitude
    end
  end

  def self.lookup(ip)
    result = GEOIP.city(ip) rescue nil
    return nil if result.nil?

    Result.new(
      country_name: santitize_string(result.country.name),
      country_code: santitize_string(result.country.iso_code),
      # Note we seem to be returning code in the past here, not the name
      region_name: santitize_string(result.most_specific_subdivision&.iso_code),
      city_name: santitize_string(result.city.name),
      postal_code: santitize_string(result.postal.code),
      latitude: santitize_string(result.location.latitude),
      longitude: santitize_string(result.location.longitude)
    )
  end

  def self.santitize_string(value)
    value.try(:encode, "UTF-8", invalid: :replace, replace: "?")
  rescue Encoding::UndefinedConversionError
    "INVALID"
  end
end
