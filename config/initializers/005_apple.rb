# frozen_string_literal: true

APPLE_CLIENT_ID = GlobalConfig.get("APPLE_WEB_CLIENT_ID")
APPLE_TEAM_ID = GlobalConfig.get("APPLE_WEB_TEAM_ID")
APPLE_KEY_ID = GlobalConfig.get("APPLE_WEB_KEY_ID")
APPLE_PRIVATE_KEY = GlobalConfig.get("APPLE_WEB_PRIVATE_KEY")

APPLE_OAUTH_COOKIE_NAME = "_apple_oauth_nonce"
APPLE_OAUTH_COOKIE_TTL = 300

# Apple's cross-site POST callback drops our SameSite=Lax session cookie,
# which breaks the default nonce verification and redirect. As a workaround
# we use a custom SameSite=None cookie to store the nonce and referer.
OmniAuth::Strategies::Apple.class_eval do
  def authorize_params
    @apple_oauth_nonce = SecureRandom.urlsafe_base64(32)
    super.merge(nonce: @apple_oauth_nonce)
  end

  def request_phase
    result = super

    cookie_data = { "nonce" => @apple_oauth_nonce }
    cookie_data["referer"] = request.params["referer"] if request.params["referer"].present?

    signed = Rails.application.message_verifier("apple_oauth").generate(
      cookie_data, purpose: :apple_oauth, expires_in: APPLE_OAUTH_COOKIE_TTL
    )

    Rack::Utils.set_cookie_header!(
      result[1],
      APPLE_OAUTH_COOKIE_NAME,
      {
        value: signed,
        path: "/users/auth/apple",
        httponly: true,
        secure: request.scheme == "https",
        same_site: :none,
        max_age: APPLE_OAUTH_COOKIE_TTL
      }
    )

    result
  end

  def callback_phase
    env["omniauth.params"] = cookie_data.except("nonce") if cookie_data

    # Apple sends `user` as a JSON string; parse it so Devise sees a hash.
    # Without this devise-pwned_password raises errors as it assumes user is a hash.
    form_hash = env["rack.request.form_hash"]
    if form_hash&.dig("user").is_a?(String)
      form_hash["user"] = JSON.parse(form_hash["user"]) rescue form_hash["user"]
    end

    super
  end

  private
    def user_info
      user = request.params["user"]
      @user_info ||= if user.is_a?(String)
        JSON.parse(user) rescue {}
      else
        user || {}
      end
    end

    def stored_nonce
      cookie_data&.dig("nonce")
    end

    def cookie_data
      @cookie_data ||= Rails.application.message_verifier("apple_oauth").verified(
        request.cookies[APPLE_OAUTH_COOKIE_NAME], purpose: :apple_oauth
      )
    end
end
