# frozen_string_literal: true

module PageMeta::Post
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    def set_post_page_meta(post, presenter)
      set_meta_tag(name: "description", content: presenter.snippet)

      set_meta_tag(property: "og:title", value: post.name)
      set_meta_tag(property: "og:description", value: presenter.snippet)
      if presenter.social_image.present?
        set_meta_tag(property: "og:image", value: presenter.social_image.url)
        set_meta_tag(property: "og:image:alt", value: presenter.social_image.caption)
      end

      set_meta_tag(property: "twitter:title", value: post.name)
      set_meta_tag(property: "twitter:description", value: presenter.snippet)
      set_meta_tag(property: "twitter:domain", value: "Gumroad")
      if presenter.social_image.present?
        set_meta_tag(property: "twitter:card", value: "summary_large_image")
        set_meta_tag(property: "twitter:image", value: presenter.social_image.url)
        set_meta_tag(property: "twitter:image:alt", value: presenter.social_image.caption)
      else
        set_meta_tag(property: "twitter:card", value: "summary")
      end
    end
end
