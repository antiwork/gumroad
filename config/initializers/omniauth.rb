# frozen_string_literal: true

OmniAuth.config.full_host = "#{PROTOCOL}://#{DOMAIN}"
OmniAuth.config.before_request_phase do |env|
  SocialConnectFunnel.record_attempted_from_omniauth!(env)
end
