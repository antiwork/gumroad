# frozen_string_literal: true

class HelpCenter::BaseController < ApplicationController
  layout "help_center"

  rescue_from ActiveHash::RecordNotFound, with: :redirect_to_help_center_root

  before_action do
    set_meta_tag(property: "og:type", value: "website")
    set_meta_tag(name: "twitter:card", content: "summary")
  end

  private
    def redirect_to_help_center_root
      redirect_to help_center_root_path, status: :found
    end
end
