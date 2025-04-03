# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Use tld_length 3 in staging to support subdomains like username.staging.gumroad.com
tld_length = Rails.env.staging? ? 3 : 2
expire_after = Rails.env.test? ? 10.years : 1.month
domain = :all

base_cookie_name = "_gumroad_app_session"
session_cookie_name =
  case Rails.env.to_sym
  when :production
    base_cookie_name
  when :staging
    if ENV["BRANCH_DEPLOYMENT"].present?
      domain = ".#{DOMAIN}"
      "#{base_cookie_name}_#{Digest::SHA256.hexdigest(DOMAIN)[0..31]}"
    else
      "#{base_cookie_name}_staging"
    end
  else
    "#{base_cookie_name}_#{Rails.env}"
  end

Rails.application.config.session_store :cookie_store,
                                       key: session_cookie_name,
                                       secure: Rails.env.production?,
                                       domain:,
                                       expire_after:,
                                       tld_length:
