# frozen_string_literal: true

module PageMeta::Base
  extend ActiveSupport::Concern
  include ActionView::Helpers::AssetUrlHelper
  include ActionView::Helpers::OutputSafetyHelper
  include ActionView::Helpers::TagHelper

  private
    def set_default_page_title
      set_meta_tag(title: default_page_title)
    end

    def page_title
      return default_page_title if (tag = title_meta_tag).blank?

      tag[:inner_content].presence || tag[:content].presence || default_page_title
    end

    def default_page_title
      case Rails.env
      when "production"
        "Gumroad"
      when "staging"
        "Staging Gumroad"
      else
        "Local Gumroad"
      end
    end

    def title_meta_tag
      inertia_meta.meta_tags.find { |tag| tag["head_key"] == "title" } || meta_tags["title"]
    end

    def set_csrf_meta_tags
      set_meta_tag(name: "csrf-param", content: request_forgery_protection_token)
      set_meta_tag(name: "csrf-token", content: form_authenticity_token)
    end

    def set_default_meta_tags
      set_meta_tag(charset: "utf-8")
      set_meta_tag(property: "fb:app_id", value: FACEBOOK_APP_ID)
      set_meta_tag(property: "fb:page_id", value: "http://www.facebook.com/gumroad")
      set_meta_tag(property: "gr:environment", value: Rails.env)
      set_meta_tag(property: "og:image", value: asset_url("opengraph_image.png"))
      set_meta_tag(property: "og:image:alt", value: "Gumroad")
      set_meta_tag(property: "og:title", value: "Gumroad")
      set_meta_tag(property: "og:site_name", value: "Gumroad")
      set_meta_tag(name: "viewport", content: "initial-scale = 1.0, width = device-width")
      set_meta_tag(property: "stripe:pk", value: STRIPE_PUBLIC_KEY)
      set_meta_tag(property: "stripe:api_version", value: Stripe.api_version)
      set_meta_tag(property: "twitter:site", value: "@gumroad")
      set_meta_tag(tag_name: "link", rel: "search", href: "/opensearch.xml", type: "application/opensearchdescription+xml", title: "Gumroad")
      set_meta_tag(tag_name: "link", rel: "shortcut icon", href: asset_url("pink-icon.png"))
      set_meta_tag(tag_name: "link", rel: "apple-touch-icon", href: asset_url("pink-icon.png"), head_key: "apple-touch-icon")
    end

    def set_meta_tag(**options)
      new_tag = InertiaRails::MetaTag.new(**options)
      meta_tags[new_tag[:head_key]] = new_tag

      inertia_meta.add([options])
    end

    def remove_meta_tag(head_key)
      meta_tags.delete(head_key)
      inertia_meta.remove(head_key)
    end

    def meta_tags
      @meta_tags ||= {}
    end

    def erb_meta_tags
      tags = meta_tags.each_value.map do |inertia_meta_tag|
        inertia_meta_tag.to_tag(tag)
      end

      safe_join(tags, "\n")
    end
end
