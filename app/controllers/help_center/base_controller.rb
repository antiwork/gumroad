# frozen_string_literal: true

class HelpCenter::BaseController < ApplicationController
  layout "help_center"

  rescue_from ActiveHash::RecordNotFound, with: :redirect_to_help_center_root

  private
    def redirect_to_help_center_root
      redirect_to help_center_root_path, status: :found
    end
end
