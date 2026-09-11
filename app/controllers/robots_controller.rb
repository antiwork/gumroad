# frozen_string_literal: true

class RobotsController < ApplicationController
  CACHE_TTL = 1.hour

  prepend_before_action { request.session_options[:skip] = true }
  skip_before_action :set_gumroad_guid

  def index
    robots_service = RobotsService.new(storefront_host: !GumroadDomainConstraint.matches?(request))
    @sitemap_configs = robots_service.sitemap_configs
    @user_agent_rules = robots_service.user_agent_rules

    expires_in CACHE_TTL, public: true
  end

  private
    def protect_against_forgery?
      false
    end
end
