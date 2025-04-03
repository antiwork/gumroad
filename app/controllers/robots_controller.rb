# frozen_string_literal: true

class RobotsController < ApplicationController
  def index
    robots_service = RobotsService.new
    @sitemap_configs = robots_service.sitemap_configs
    @user_agent_rules = robots_service.user_agent_rules
  end
end
