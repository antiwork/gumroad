# frozen_string_literal: true

module RiskState
  MAX_MIND_LICENSE_KEY = "B3Ti8SeX3v6Z"

  module_function

  def get_ip_proxy_score(ip_address, timeout = 3)
    return 0 if ip_address.nil?

    params = {
      i: ip_address,
      l: MAX_MIND_LICENSE_KEY
    }

    begin
      request = HTTParty.get("https://minfraud.maxmind.com/app/ipauth_http", query: params, timeout:)
    rescue *INTERNET_EXCEPTIONS
      return 0
    end
    response = request.parsed_response.split("=")
    if response.first == "proxyScore" && response.count > 1
      response.last.to_f
    else
      0
    end
  end
end
