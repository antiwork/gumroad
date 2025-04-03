# frozen_string_literal: true

class GoogleCalendarApi
  include HTTParty

  GOOGLE_CALENDAR_OAUTH_URL = "https://oauth2.googleapis.com"
  base_uri "https://www.googleapis.com/"

  def oauth_token(code, redirect_uri)
    body = {
      grant_type: "authorization_code",
      code:,
      redirect_uri:,
      client_id: GlobalConfig.get("GOOGLE_CLIENT_ID"),
      client_secret: GlobalConfig.get("GOOGLE_CLIENT_SECRET"),
    }

    HTTParty.post("#{GOOGLE_CALENDAR_OAUTH_URL}/token", body: URI.encode_www_form(body))
  end

  def calendar_list(token)
    rate_limited_call { self.class.get("/calendar/v3/users/me/calendarList", headers: request_header(token)) }
  end

  def user_info(token)
    rate_limited_call { self.class.get("/oauth2/v2/userinfo", query: { access_token: token }) }
  end

  def disconnect(token)
    HTTParty.post("#{GOOGLE_CALENDAR_OAUTH_URL}/revoke", query: { token: }, headers: { "Content-type" => "application/x-www-form-urlencoded" })
  end

  def refresh_token(refresh_token)
    body = {
      grant_type: "refresh_token",
      refresh_token:,
      client_id: GlobalConfig.get("GOOGLE_CLIENT_ID"),
      client_secret: GlobalConfig.get("GOOGLE_CLIENT_SECRET"),
    }

    HTTParty.post("#{GOOGLE_CALENDAR_OAUTH_URL}/token", body: URI.encode_www_form(body))
  end

  def insert_event(calendar_id, event, access_token:)
    headers = request_header(access_token)
    rate_limited_call do
      self.class.post(
        "/calendar/v3/calendars/#{calendar_id}/events",
        headers: headers,
        body: event.to_json
      )
    end
  end

  private
    def request_header(token)
      { "Authorization" => "Bearer #{token}" }
    end

    def rate_limited_call(&block)
      key = "GOOGLE_CALENDAR_API_RATE_LIMIT"
      ratelimit = Ratelimit.new(key, { redis: $redis })

      ratelimit.exec_within_threshold key, threshold: 10000, interval: 60 do
        ratelimit.add(key)
        block.call
      end
    end
end
