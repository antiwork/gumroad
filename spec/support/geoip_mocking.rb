# frozen_string_literal: true

RSpec.configure do |config|
  config.before(:each) do
    full_description = RSpec.current_example&.full_description || ""
    if full_description.include?("invalid UTF-8") || full_description.include?("underlying GEOIP has invalid")
      allow(GEOIP).to receive(:city).and_return(
        double(
          country: double({ name: "Unit\xB7ed States", iso_code: "U\xB7S" }),
          most_specific_subdivision: double({ iso_code: "C\xB7A" }),
          city: double({ name: "San F\xB7rancisco" }),
          postal: double({ code: "941\xB703" }),
          location: double({ latitude: "103\xB7103", longitude: "103\xB7103" })
        )
      )
    else
      geoip_mock_data = {
        # Private/local IPs
        "127.0.0.1" => nil,
        "192.168.1.1" => nil,

        # North America
        "54.234.242.13" => { country: "United States", code: "US", region: "VA", city: "Ashburn", postal: "20147" },
        "104.193.168.19" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "199.241.200.176" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "216.38.135.1" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "4.167.234.0" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "12.38.32.0" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "64.115.250.0" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "67.183.58.7" => { country: "United States", code: "US", region: "WA", city: "Seattle", postal: "98101" },
        "72.229.28.185" => { country: "United States", code: "US", region: "NY", city: "New York", postal: "10001" },
        "12.12.128.128" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "101.198.198.0" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "199.21.86.138" => { country: "United States", code: "US", region: "CA", city: "San Francisco", postal: "94110" },
        "76.66.210.142" => { country: "Canada", code: "CA", region: "ON", city: "Toronto", postal: "M5H 2N2" },
        "184.65.213.114" => { country: "Canada", code: "CA", region: "BC", city: "Vancouver", postal: "V6B 1A1" },
        "192.206.151.131" => { country: "Canada", code: "CA", region: "ON", city: "Toronto", postal: "M5H 2N2" },
        "104.163.219.131" => { country: "Canada", code: "CA", region: "QC", city: "Montreal", postal: "H1A 0A1" },

        # Europe
        "2.47.255.255" => { country: "Italy", code: "IT", region: "RM", city: "Rome", postal: "00100" },
        "93.99.163.13" => { country: "Czechia", code: "CZ", region: "10", city: "Prague", postal: "11000" },
        "46.140.123.45" => { country: "Switzerland", code: "CH", region: "ZH", city: "Zurich", postal: "8001" },
        "84.210.138.89" => { country: "Norway", code: "NO", region: "03", city: "Oslo", postal: "0150" },
        "213.220.126.106" => { country: "Iceland", code: "IS", region: "1", city: "Reykjavik", postal: "101" },
        "85.127.28.23" => { country: "Austria", code: "AT", region: "9", city: "Vienna", postal: "1010" },
        "176.36.232.147" => { country: "Ukraine", code: "UA", region: "30", city: "Kiev", postal: "01001" },
        "178.168.0.1" => { country: "Moldova", code: "MD", region: "C", city: "Chisinau", postal: "2000" },
        "178.220.0.1" => { country: "Serbia", code: "RS", region: "00", city: "Belgrade", postal: "11000" },
        "93.84.113.217" => { country: "Belarus", code: "BY", region: "HM", city: "Minsk", postal: "220000" },
        "95.167.0.0" => { country: "Russia", code: "RU", region: "MOW", city: "Moscow", postal: "101000" },
        "193.145.138.32" => { country: "Switzerland", code: "CH", region: "ZH", city: "Zurich", postal: "8001" },
        "193.145.147.158" => { country: "Switzerland", code: "CH", region: "ZH", city: "Zurich", postal: "8001" },
        "182.23.143.254" => { country: "Turkey", code: "TR", region: "34", city: "Istanbul", postal: "34000" },

        # Asia-Pacific
        "103.251.65.149" => { country: "Australia", code: "AU", region: "NSW", city: "Sydney", postal: "2000" },
        "103.6.151.4" => { country: "Singapore", code: "SG", region: "01", city: "Singapore", postal: "018956" },
        "126.0.0.1" => { country: "Japan", code: "JP", region: "13", city: "Tokyo", postal: "100-0001" },
        "121.72.165.118" => { country: "New Zealand", code: "NZ", region: "AUK", city: "Auckland", postal: "1010" },
        "1.174.208.0" => { country: "Taiwan", code: "TW", region: "TPE", city: "Taipei", postal: "100" },
        "1.208.105.19" => { country: "South Korea", code: "KR", region: "11", city: "Seoul", postal: "04524" },
        "1.255.49.75" => { country: "South Korea", code: "KR", region: "11", city: "Seoul", postal: "04524" },
        "103.48.196.103" => { country: "India", code: "IN", region: "DL", city: "New Delhi", postal: "110001" },
        "113.161.94.110" => { country: "Vietnam", code: "VN", region: "79", city: "Ho Chi Minh City", postal: "700000" },
        "171.96.70.108" => { country: "Thailand", code: "TH", region: "10", city: "Bangkok", postal: "10200" },
        "175.143.0.1" => { country: "Malaysia", code: "MY", region: "14", city: "Kuala Lumpur", postal: "50000" },
        "78.188.0.1" => { country: "Turkey", code: "TR", region: "34", city: "Istanbul", postal: "34000" },

        # Africa & Middle East
        "196.25.255.250" => { country: "South Africa", code: "ZA", region: "WC", city: "Cape Town", postal: "8000" },
        "41.184.122.50" => { country: "Nigeria", code: "NG", region: "LA", city: "Lagos", postal: "100001" },
        "84.235.49.128" => { country: "Saudi Arabia", code: "SA", region: "01", city: "Riyadh", postal: "11564" },
        "185.93.245.44" => { country: "United Arab Emirates", code: "AE", region: "DU", city: "Dubai", postal: "00000" },
        "156.208.0.0" => { country: "Egypt", code: "EG", region: "C", city: "Cairo", postal: "11511" },
        "105.158.0.1" => { country: "Morocco", code: "MA", region: "07", city: "Casablanca", postal: "20000" },
        "31.146.180.0" => { country: "Georgia", code: "GE", region: "TB", city: "Tbilisi", postal: "0100" },
        "41.188.156.75" => { country: "Tanzania", code: "TZ", region: "26", city: "Dar es Salaam", postal: "11000" },
        "41.90.0.1" => { country: "Kenya", code: "KE", region: "110", city: "Nairobi", postal: "00100" },
        "5.37.0.0" => { country: "Oman", code: "OM", region: "MA", city: "Muscat", postal: "112" },
        "77.69.128.1" => { country: "Bahrain", code: "BH", region: "13", city: "Manama", postal: "317" },

        # Americas (South/Central)
        "181.49.0.1" => { country: "Colombia", code: "CO", region: "DC", city: "Bogota", postal: "110111" },
        "186.101.88.2" => { country: "Ecuador", code: "EC", region: "P", city: "Quito", postal: "170150" },
        "186.15.0.1" => { country: "Costa Rica", code: "CR", region: "SJ", city: "San Jose", postal: "1000" },
        "187.189.0.1" => { country: "Mexico", code: "MX", region: "CMX", city: "Mexico City", postal: "06000" },
        "189.144.240.120" => { country: "Mexico", code: "MX", region: "CMX", city: "Mexico City", postal: "06000" },
        "200.68.0.1" => { country: "Chile", code: "CL", region: "RM", city: "Santiago", postal: "8320000" },

        # Other Regions
        "2.132.97.1" => { country: "Kazakhstan", code: "KZ", region: "ALA", city: "Almaty", postal: "050000" },
        "91.196.77.77" => { country: "Uzbekistan", code: "UZ", region: "TK", city: "Tashkent", postal: "100000" },
        "41.208.70.70" => { country: "Libya", code: "LY", region: "TB", city: "Tripoli", postal: "00000" },
        "109.110.31.255" => { country: "Latvia", code: "LV", region: "RIX", city: "Riga", postal: "LV-1000" },

        # IPv6 addresses
        "2001:861:5bc0:cb60:500d:3535:e6a7:62a0" => { country: "France", code: "FR", region: "BFC", city: "Belfort", postal: "90000" }
      }

      allow(GeoIp).to receive(:lookup) do |ip|
        data = geoip_mock_data[ip]
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
end
