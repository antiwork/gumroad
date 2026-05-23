# frozen_string_literal: true

module GeoipMocking
  GEOIP_MOCK_DATA = {
    "127.0.0.1" => nil,
    "192.168.1.1" => nil,
    "54.234.242.13" => { country: "United States", code: "US", region: "VA", city: "Ashburn", postal: "20147" },
    "104.193.168.19" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
    "199.241.200.176" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
    "76.66.210.142" => { country: "Canada", code: "CA", region: "ON", city: "Toronto", postal: "M5H 2N2" },
    "2.47.255.255" => { country: "Italy", code: "IT", region: "RM", city: "Rome", postal: "00100" },
    "93.99.163.13" => { country: "Czechia", code: "CZ", region: "10", city: "Prague", postal: "11000" },
    "46.140.123.45" => { country: "Switzerland", code: "CH", region: "ZH", city: "Zurich", postal: "8001" },
    "103.251.65.149" => { country: "Australia", code: "AU", region: "NSW", city: "Sydney", postal: "2000" },
    "103.6.151.4" => { country: "Singapore", code: "SG", region: "01", city: "Singapore", postal: "018956" },
    "126.0.0.1" => { country: "Japan", code: "JP", region: "13", city: "Tokyo", postal: "100-0001" },
    "103.48.196.103" => { country: "India", code: "IN", region: "DL", city: "New Delhi", postal: "110001" },
    "196.25.255.250" => { country: "South Africa", code: "ZA", region: "WC", city: "Cape Town", postal: "8000" },
    "41.184.122.50" => { country: "Nigeria", code: "NG", region: "LA", city: "Lagos", postal: "100001" },
    "181.49.0.1" => { country: "Colombia", code: "CO", region: "DC", city: "Bogota", postal: "110111" },
  }.freeze

  def stub_geoip
    allow(GeoIp).to receive(:lookup) do |ip|
      data = GEOIP_MOCK_DATA[ip]
      next nil if data.nil?

      GeoIp::Result.new(
        country_name: data[:country],
        country_code: data[:code],
        region_name: data[:region],
        city_name: data[:city],
        postal_code: data[:postal],
        latitude: nil,
        longitude: nil
      )
    end
  end
end
