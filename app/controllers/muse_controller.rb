# frozen_string_literal: true

class MuseController < ApplicationController
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
      title = "Gumroad for Muse"
      description = "Connect Muse to Gumroad. Creators can ask Muse to list sales, draft a product, publish it, and check payouts."

      set_meta_tag(title:)
      set_meta_tag(name: "description", content: description)
      set_meta_tag(tag_name: "link", rel: "canonical", href: muse_url, head_key: "canonical")
      set_meta_tag(property: "og:title", content: title)
      set_meta_tag(property: "og:description", content: description)
      set_meta_tag(property: "og:type", content: "website")
      set_meta_tag(property: "og:url", content: muse_url)
    end
end
