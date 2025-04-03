# frozen_string_literal: true

class DiscordApi
  def oauth_token(code, redirect_uri)
    body = {
      grant_type: "authorization_code",
      code:,
      client_id: DISCORD_CLIENT_ID,
      client_secret: DISCORD_CLIENT_SECRET,
      redirect_uri:
    }

    headers = { "Content-Type" => "application/x-www-form-urlencoded" }

    HTTParty.post(DISCORD_OAUTH_TOKEN_URL, body: URI.encode_www_form(body), headers:)
  end

  def identify(token)
    Discordrb::API::User.profile(bearer_token(token))
  end

  def disconnect(server)
    Discordrb::API::User.leave_server(bot_token, server)
  end

  def add_member(server, user, access_token)
    Discordrb::API::Server.add_member(bot_token, server, user, access_token)
  end

  def remove_member(server, user)
    Discordrb::API::Server.remove_member(bot_token, server, user)
  end

  def resolve_member(server, user)
    Discordrb::API::Server.resolve_member(bot_token, server, user)
  end

  def roles(server)
    Discordrb::API::Server.roles(bot_token, server)
  end

  private
    def bot_token
      "Bot #{DISCORD_BOT_TOKEN}"
    end

    def bearer_token(token)
      "Bearer #{token}"
    end
end
