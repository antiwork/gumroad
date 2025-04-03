# frozen_string_literal: true

if Rails.env.production?
  CUSTOM_DOMAIN_CNAME = GlobalConfig.get("CUSTOM_DOMAIN_CNAME_PROD", "domains.gumroad.com")

  # CUSTOM_DOMAIN_STATIC_IP_HOST is for internal use. It will be used only to
  # check if the custom domain is pointed to the static IP address.
  CUSTOM_DOMAIN_STATIC_IP_HOST = GlobalConfig.get("CUSTOM_DOMAIN_STATIC_IP_HOST_PROD", "production-custom-domains-static-ip.gumroad.net")
else
  CUSTOM_DOMAIN_CNAME = GlobalConfig.get("CUSTOM_DOMAIN_CNAME_STAGING", "domains-staging.gumroad.com")
  CUSTOM_DOMAIN_STATIC_IP_HOST = GlobalConfig.get("CUSTOM_DOMAIN_STATIC_IP_HOST_STAGING", "staging-custom-domains-static-ip.gumroad.net")
end
