# frozen_string_literal: true

class CommunitiesController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized
  before_action :set_body_id_as_app

  def index
    @hide_layouts = true

    authorize Community
  end

  private
    def set_default_page_title
      set_meta_tag(title: "Communities")
    end
end
