# frozen_string_literal: true

class ZoomApi
  include HTTParty

  ZOOM_OAUTH_URL = "https://zoom.us/oauth/token"
  base_uri "https://api.zoom.us/v2"

  def oauth_token(code, redirect_uri)
    body = {
      grant_type: "authorization_code",
      code:,
      redirect_uri:
    }

    HTTParty.post(ZOOM_OAUTH_URL, body: URI.encode_www_form(body), headers: oauth_header)
  end

  def user_info(token)
    rate_limited_call { self.class.get("/users/me", headers: request_header(token)) }
  end

  private
    def oauth_header
      client_id = GlobalConfig.get("ZOOM_CLIENT_ID")
      client_secret = GlobalConfig.get("ZOOM_CLIENT_SECRET")
      token = Base64.strict_encode64("#{client_id}:#{client_secret}")

      { "Authorization" => "Basic #{token}", "Content-Type" => "application/x-www-form-urlencoded" }
    end

    def request_header(token)
      { "Authorization" => "Bearer #{token}" }
    end

    def rate_limited_call(&block)
      key = "ZOOM_API_RATE_LIMIT"
      ratelimit = Ratelimit.new(key, { redis: $redis })

      ratelimit.exec_within_threshold key, threshold: 30, interval: 1 do
        ratelimit.add(key)
        block.call
      end
    end
end
