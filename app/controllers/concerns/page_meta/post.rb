# frozen_string_literal: true

module PageMeta::Post
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    def set_post_page_meta(post, presenter)
      set_meta_tag(name: "description", content: presenter.snippet)

      set_meta_tag(property: "og:title", content: post.name)
      set_meta_tag(property: "og:description", content: presenter.snippet)
      if presenter.social_image.present?
        set_meta_tag(property: "og:image", content: presenter.social_image.url)
        set_meta_tag(property: "og:image:alt", content: presenter.social_image.caption)
      end

      set_meta_tag(property: "twitter:title", content: post.name)
      set_meta_tag(property: "twitter:description", content: presenter.snippet)
      set_meta_tag(property: "twitter:domain", content: "Gumroad")
      if presenter.social_image.present?
        set_meta_tag(property: "twitter:card", content: "summary_large_image")
        set_meta_tag(property: "twitter:image", content: presenter.social_image.url)
        set_meta_tag(property: "twitter:image:alt", content: presenter.social_image.caption)
      else
        set_meta_tag(property: "twitter:card", content: "summary")
      end
    end
end
