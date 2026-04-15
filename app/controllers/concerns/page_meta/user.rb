# frozen_string_literal: true

module PageMeta::User
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    def set_user_page_meta(user)
      set_meta_tag(property: "og:site_name", value: "Gumroad")
      set_meta_tag(property: "og:type", value: "website")

      if user.bio.present?
        title = "Subscribe to #{user.name_or_username} on Gumroad"
        description = user.bio.squish.first(300)
      else
        title = "Subscribe to #{user.name_or_username}"
        description = "On Gumroad"
      end
      set_meta_tag(property: "og:title", value: title)
      set_meta_tag(name: "description", content: description)
      set_meta_tag(property: "og:description", value: description)

      if user.subscribe_preview_url.present?
        set_meta_tag(property: "twitter:card", value: "summary_large_image")
        set_meta_tag(property: "twitter:image", value: user.subscribe_preview_url)
        set_meta_tag(property: "twitter:image:alt", value: user.name_or_username)
      else
        if user.name.present?
          set_meta_tag(property: "og:title", value: user.name)
        end
        if user.avatar_url.present?
          set_meta_tag(property: "og:image", value: user.avatar_url)
          set_meta_tag(property: "og:image:alt", value: "#{user.name_or_username}'s profile picture")
        end
      end

      if user.seller_profile.custom_styles.present?
        set_meta_tag(tag_name: "style", inner_content: user.seller_profile.custom_styles.to_s, head_key: "custom_styles")
      end
    end
end
