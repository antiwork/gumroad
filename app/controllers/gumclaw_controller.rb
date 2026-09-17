# frozen_string_literal: true

class GumclawController < ApplicationController
  layout "home"

  before_action :set_body_class
  before_action :set_meta_data

  def index
  end

  private
    def set_body_class
      @hide_layouts = true
    end

    def set_meta_data
      title = "Gumclaw - The agent that runs Gumroad"
      description = "Gumroad is run by Gumclaw, an autonomous AI agent that handles support, operations, and engineering. Learn how we build at Antiwork."

      set_meta_tag(title: title)
      set_meta_tag(name: "description", content: description)
      set_meta_tag(tag_name: "link", rel: "canonical", href: gumclaw_url, head_key: "canonical")
      set_meta_tag(property: "og:title", content: title)
      set_meta_tag(property: "og:description", content: description)
      set_meta_tag(property: "og:type", content: "website")
      set_meta_tag(property: "og:url", content: gumclaw_url)
    end
end
