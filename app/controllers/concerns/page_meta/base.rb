# frozen_string_literal: true

module PageMeta::Base
  extend ActiveSupport::Concern
  include ActionView::Helpers::OutputSafetyHelper
  include ActionView::Helpers::TagHelper

  delegate :image_path, to: "ActionController::Base.helpers"

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
      set_meta_tag(property: "fb:app_id", content: FACEBOOK_APP_ID)
      set_meta_tag(property: "fb:page_id", content: "http://www.facebook.com/gumroad")
      set_meta_tag(property: "gr:environment", content: Rails.env)
      set_meta_tag(property: "og:image", content: image_path("opengraph_image.png"))
      set_meta_tag(property: "og:image:alt", content: "Gumroad")
      set_meta_tag(property: "og:title", content: "Gumroad")
      set_meta_tag(property: "og:site_name", content: "Gumroad")
      set_meta_tag(name: "viewport", content: "initial-scale = 1.0, width = device-width")
      # NOTE: stripe:pk / stripe:api_version are NOT Open Graph tags — they are read by our OWN
      # frontend (app/javascript/utils/stripe_loader.ts) via getAttribute("value"), so they must
      # keep the `value:` key. Scrapers never read them, so the OG content= fix does not apply here.
      set_meta_tag(property: "stripe:pk", value: STRIPE_PUBLIC_KEY)
      set_meta_tag(property: "stripe:api_version", value: Stripe.api_version)
      set_meta_tag(property: "twitter:site", content: "@gumroad")
      set_meta_tag(tag_name: "link", rel: "search", href: "/opensearch.xml", type: "application/opensearchdescription+xml", title: "Gumroad")
      set_meta_tag(tag_name: "link", rel: "shortcut icon", href: image_path("pink-icon.png"))
      set_meta_tag(tag_name: "link", rel: "apple-touch-icon", href: image_path("pink-icon.png"), head_key: "apple-touch-icon")
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
