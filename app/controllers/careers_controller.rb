# frozen_string_literal: true

class CareersController < ApplicationController
  layout "home"

  before_action { e404 if Feature.inactive?(:career_pages) }
  before_action :set_body_class
  before_action :set_meta_data

  def index
    @jobs = JOBS
  end

  def show
    @job = JOBS.find { |j| j[:slug] == params[:slug] }
    raise ActionController::RoutingError, "Not Found" unless @job
    @title = "#{@job[:title]} - Gumroad Careers"
  end

  private
    def set_body_class
      @hide_layouts = true
    end

    def set_meta_data
      @title = "Careers at Gumroad - Build the road with us"
      @meta_data = {
        "index" => {
          url: :careers_url,
          title: @title,
          description: "Join us to build the #1 tool for creators. Explore open roles and help shape the future of digital commerce."
        }
      }
    end
end
