# frozen_string_literal: true

class GumclawController < ApplicationController
  layout "home"

  before_action { e404 if Feature.inactive?(:career_pages) }
  before_action :set_body_class
  before_action :set_meta_data

  def index
  end

  private
    def set_body_class
      @hide_layouts = true
    end

    def set_meta_data
      @title = "Gumclaw - The agent that runs Gumroad"
      @meta_data = {
        "index" => {
          url: :gumclaw_url,
          title: @title,
          description: "Gumroad is run by Gumclaw, an autonomous AI agent that handles support, operations, and engineering. Learn how we build at Antiwork."
        }
      }
    end
end
