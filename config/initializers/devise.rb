# frozen_string_literal: true

require "omniauth-apple"
require "omniauth-twitter"
require "omniauth-google-oauth2"
require_relative "../../lib/omni_auth/strategies/youtube"
require_relative "../../lib/omni_auth/strategies/instagram"
require_relative "../../lib/omni_auth/strategies/tiktok"

Devise.setup do |config|
  # Changing this invalidates existing confirmation, reset-password, and unlock tokens.
  config.secret_key = ENV.fetch("DEVISE_SECRET_KEY")

  config.mailer_sender = ->(_devise_mapping) { ApplicationMailer::NOREPLY_EMAIL_WITH_NAME }
  config.mailer = "UserSignupMailer"

  require "devise/orm/active_record"

  # :login, not :email — keep these three in lockstep.
  config.authentication_keys = [:login]
  config.case_insensitive_keys = [:login]
  config.strip_whitespace_keys = [:login]

  # 1 in test for speed. Do not use <10 elsewhere — bcrypt cost is exponential.
  config.stretches = Rails.env.test? ? 1 : 11

  config.pepper = GlobalConfig.get("DEVISE_PEPPER")
  config.send_email_changed_notification = true
  config.reconfirmable = true
  config.remember_for = 1.month
  config.password_length = 6..128
  config.reset_password_within = 24.hours
  # Devise default is true.
  config.sign_in_after_reset_password = false
  config.sign_out_via = :delete

  config.omniauth :twitter,
                  TWITTER_APP_ID,
                  TWITTER_APP_SECRET

  config.omniauth :stripe_connect,
                  STRIPE_CONNECT_CLIENT_ID,
                  STRIPE_SECRET,
                  scope: "read_write"

  config.omniauth :google_oauth2,
                  GOOGLE_CLIENT_ID,
                  GOOGLE_CLIENT_SECRET,
                  scope: "email,profile"

  # YouTube connect only — does not change Google login scopes.
  config.omniauth :youtube,
                  GOOGLE_CLIENT_ID,
                  GOOGLE_CLIENT_SECRET

  config.omniauth :instagram,
                  INSTAGRAM_APP_ID,
                  INSTAGRAM_APP_SECRET

  config.omniauth :tiktok,
                  TIKTOK_CLIENT_KEY,
                  TIKTOK_CLIENT_SECRET

  config.omniauth :apple,
                  APPLE_CLIENT_ID,
                  "",
                  scope: "email name",
                  team_id: APPLE_TEAM_ID,
                  key_id: APPLE_KEY_ID,
                  pem: APPLE_PRIVATE_KEY,
                  provider_ignores_state: true

  config.router_name = :main_app
end
