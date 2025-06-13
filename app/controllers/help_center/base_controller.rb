# frozen_string_literal: true

class HelpCenter::BaseController < ApplicationController
  layout "help_center"

  before_action :ensure_feature_is_enabled

  private
    def ensure_feature_is_enabled
      return if logged_in_user&.is_team_member?
      return if Feature.active?(:help_center)

      e404
    end
end
