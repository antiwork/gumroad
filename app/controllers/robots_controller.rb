# frozen_string_literal: true

class RobotsController < ApplicationController
  CACHE_TTL = 1.hour

  # robots.txt is identical for every visitor on a host, but a Set-Cookie header
  # stops Cloudflare caching the response — which is why crawler hits reach Rails
  # today (gumroad-private#2488). Suppress the session, guid and CSRF cookies the
  # way HomeController does for its edge-cacheable marketing pages. Prepended so
  # the session is already skipped before callbacks try to write to it.
  prepend_before_action { request.session_options[:skip] = true }

  def index
    robots_service = RobotsService.new(storefront_host: !GumroadDomainConstraint.matches?(request))
    @sitemap_configs = robots_service.sitemap_configs
    @user_agent_rules = robots_service.user_agent_rules

    expires_in CACHE_TTL, public: true
  end

  private
    # ApplicationController hands every visitor a _gumroad_guid analytics cookie.
    def set_gumroad_guid
    end

    # inertia_rails writes an XSRF-TOKEN cookie whenever forgery protection is on.
    def protect_against_forgery?
      false
    end
end
