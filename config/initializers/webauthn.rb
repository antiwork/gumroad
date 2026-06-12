# frozen_string_literal: true

webauthn_host = ->(host) { host.to_s.split(":").first }
webauthn_origin = ->(host) { "#{PROTOCOL}://#{host}" }

WebAuthn.configure do |config|
  config.rp_name = "Gumroad"
  config.rp_id = webauthn_host.call(ROOT_DOMAIN)
  config.allowed_origins = (VALID_REQUEST_HOSTS + [DOMAIN, ROOT_DOMAIN]).uniq.map { |host| webauthn_origin.call(host) }
end
