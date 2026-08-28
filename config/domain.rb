# frozen_string_literal: true

# bin/dev-lane exports DEV_LANE_PORT per lane; without it every absolute URL a
# nonzero lane generates (mailer links, *_url helpers, cross-subdomain redirects)
# would point at lane 0's :3000. Port-less entries (valid_discover_host, the bare
# valid_request_hosts) must stay port-less — they are compared against
# request.host, which never carries a port.
dev_lane_port = ENV.fetch("DEV_LANE_PORT", "3000")

configuration_by_env = {
  production: {
    protocol: "https",
    domain: "gumroad.com",
    asset_domain: "assets.gumroad.com",
    root_domain: "gumroad.com",
    short_domain: "gum.co",
    discover_domain: "gumroad.com",
    api_domain: "api.gumroad.com",
    third_party_analytics_domain: "gumroad-analytics.com",
    valid_request_hosts: ["gumroad.com", "app.gumroad.com"],
    valid_api_request_hosts: ["api.gumroad.com"],
    valid_discover_host: "gumroad.com",
    valid_cors_origins: ["gumroad.com"],
    internal_gumroad_domain: "gumroad.net",
    default_email_domain: "gumroad.com",
    anycable_host: "cable.gumroad.com",
  },
  staging: {
    protocol: "https",
    domain: "staging.gumroad.com",
    asset_domain: "staging-assets.gumroad.com",
    root_domain: "staging.gumroad.com",
    short_domain: "staging.gum.co",
    discover_domain: "staging.gumroad.com",
    api_domain: "api.staging.gumroad.com",
    third_party_analytics_domain: "staging.gumroad-analytics.com",
    valid_request_hosts: ["staging.gumroad.com", "app.staging.gumroad.com"],
    valid_api_request_hosts: ["api.staging.gumroad.com"],
    valid_discover_host: "staging.gumroad.com",
    valid_cors_origins: ["staging.gumroad.com"],
    internal_gumroad_domain: "gumroad.net",
    default_email_domain: "staging.gumroad.com",
    anycable_host: "cable.staging.gumroad.com",
  },
  test: {
    protocol: "http",
    domain: "app.test.gumroad.com:31337",
    asset_domain: "test.gumroad.com:31337",
    root_domain: "test.gumroad.com:31337",
    short_domain: "short-domain.test.gumroad.com:31337",
    discover_domain: "test.gumroad.com:31337",
    api_domain: "api.test.gumroad.com:31337",
    third_party_analytics_domain: "analytics.test.gumroad.com",
    valid_request_hosts: ["127.0.0.1", "app.test.gumroad.com", "test.gumroad.com"],
    valid_api_request_hosts: ["api.test.gumroad.com"],
    valid_discover_host: "test.gumroad.com",
    valid_cors_origins: ["help.test.gumroad.com", "customers.test.gumroad.com"],
    internal_gumroad_domain: "test.gumroad.net",
    default_email_domain: "test.gumroad.com", # unused
    anycable_host: "cable.test.gumroad.com",
  },
  development: {
    protocol: "http",
    domain: "localhost:#{dev_lane_port}",
    asset_domain: "app.localhost:#{dev_lane_port}",
    root_domain: "localhost:#{dev_lane_port}",
    short_domain: "s.localhost:#{dev_lane_port}",
    discover_domain: "localhost:#{dev_lane_port}",
    api_domain: "api.localhost:#{dev_lane_port}",
    third_party_analytics_domain: "analytics.localhost:#{dev_lane_port}",
    valid_request_hosts: ["app.localhost", "localhost", "app.localhost:#{dev_lane_port}", "localhost:#{dev_lane_port}"],
    valid_api_request_hosts: ["api.localhost", "api.localhost:#{dev_lane_port}"],
    valid_discover_host: "localhost",
    valid_cors_origins: [],
    internal_gumroad_domain: "internal.localhost",
    default_email_domain: "staging.gumroad.com",
    anycable_host: "cable.localhost",
  }
}

custom_domain       = ENV["CUSTOM_DOMAIN"]
custom_short_domain = ENV["CUSTOM_SHORT_DOMAIN"]
environment         = ENV["RAILS_ENV"]&.to_sym || :development
config              = configuration_by_env[environment]

# CUSTOM_PROTOCOL pairs with CUSTOM_DOMAIN for local HTTPS work — running the mobile app against
# a local backend, for example. Without it, CUSTOM_DOMAIN changes the host but development stays
# on "http", so asset and redirect URLs point at http://app.localhost:3000 and every page the
# mobile app embeds in an HTTPS WebView renders blank with no error on either side.
PROTOCOL            = ENV["CUSTOM_PROTOCOL"] || config[:protocol]
DOMAIN              = custom_domain || config[:domain]
ASSET_DOMAIN        = ENV["ASSET_DOMAIN"] || config[:asset_domain]
ROOT_DOMAIN         = custom_domain || config[:root_domain]
SHORT_DOMAIN        = custom_short_domain || config[:short_domain]
API_DOMAIN          = config[:api_domain]
THIRD_PARTY_ANALYTICS_DOMAIN = config[:third_party_analytics_domain]
VALID_REQUEST_HOSTS = config[:valid_request_hosts]
VALID_API_REQUEST_HOSTS = config[:valid_api_request_hosts]
VALID_CORS_ORIGINS = config[:valid_cors_origins]
INTERNAL_GUMROAD_DOMAIN = config[:internal_gumroad_domain]
DEFAULT_EMAIL_DOMAIN    = config[:default_email_domain]
ANYCABLE_HOST           = config[:anycable_host]

if custom_domain
  VALID_REQUEST_HOSTS << custom_domain
  VALID_API_REQUEST_HOSTS << "api.#{custom_domain}"
  VALID_API_REQUEST_HOSTS << custom_domain if ENV["BRANCH_DEPLOYMENT"].present? # Allow CORS to preview app's root domain
  VALID_CORS_ORIGINS << custom_domain
  DISCOVER_DOMAIN = custom_domain
  VALID_DISCOVER_REQUEST_HOST = custom_domain
else
  DISCOVER_DOMAIN = config[:discover_domain]
  VALID_DISCOVER_REQUEST_HOST = config[:valid_discover_host]
end

if environment == :development && !ENV["LOCAL_PROXY_DOMAIN"].nil?
  VALID_REQUEST_HOSTS << ENV["LOCAL_PROXY_DOMAIN"].sub(/https?:\/\//, "")
end
