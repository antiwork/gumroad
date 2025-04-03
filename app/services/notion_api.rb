# frozen_string_literal: true

class NotionApi
  include HTTParty

  base_uri "https://api.notion.com/v1"

  def get_bot_token(code:, user:)
    body = {
      code:,
      grant_type: "authorization_code",
      external_account: {
        key: user.external_id,
        name: user.email
      }
    }
    self.class.post("/oauth/token", body: body.to_json, headers:)
  end

  private
    def headers
      client_id = GlobalConfig.get("NOTION_OAUTH_CLIENT_ID")
      client_secret = GlobalConfig.get("NOTION_OAUTH_CLIENT_SECRET")
      token = Base64.strict_encode64("#{client_id}:#{client_secret}")

      {
        "Authorization" => "Basic #{token}",
        "Content-Type" => "application/json"
      }
    end
end
