# frozen_string_literal: true

module PageMeta::User
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    def set_user_page_meta(user)
      set_meta_tag(property: "og:site_name", content: "Gumroad")
      set_meta_tag(property: "og:type", content: "website")

      if user.bio.present?
        title = "Subscribe to #{user.name_or_username} on Gumroad"
        description = user.bio.squish.first(300)
      else
        title = "Subscribe to #{user.name_or_username}"
        description = "On Gumroad"
      end
      set_meta_tag(property: "og:title", content: title)
      set_meta_tag(name: "description", content: description)
      set_meta_tag(property: "og:description", content: description)

      if user.subscribe_preview_url.present?
        set_meta_tag(property: "og:image", content: user.subscribe_preview_url)
        # Dimensions + type let Facebook's crawler render the card on the FIRST
        # share after a scrape; without them it processes the image async and the
        # first preview goes out imageless (which sellers report as "blank circle").
        set_meta_tag(property: "og:image:type", content: "image/png")
        set_meta_tag(property: "og:image:width", content: SubscribePreviewGeneratorService::OUTPUT_WIDTH.to_s)
        set_meta_tag(property: "og:image:height", content: SubscribePreviewGeneratorService::OUTPUT_HEIGHT.to_s)
        set_meta_tag(property: "og:image:alt", content: user.name_or_username)
        set_meta_tag(property: "twitter:card", content: "summary_large_image")
        set_meta_tag(property: "twitter:image", content: user.subscribe_preview_url)
        set_meta_tag(property: "twitter:image:alt", content: user.name_or_username)
      else
        if user.name.present?
          set_meta_tag(property: "og:title", content: user.name)
        end
        # avatar_url always returns something — it falls back to Gumroad's default
        # avatar — so a presence check here would advertise that placeholder as the
        # seller's share image. Only a real upload is worth announcing; with neither
        # a card nor an avatar, omitting the tag lets scrapers use their own fallback.
        if user.avatar.attached?
          set_meta_tag(property: "og:image", content: user.avatar_url)
          set_meta_tag(property: "og:image:alt", content: "#{user.name_or_username}'s profile picture")
        end
      end

      if user.seller_profile.custom_styles.present?
        set_meta_tag(tag_name: "style", inner_content: user.seller_profile.custom_styles.to_s, head_key: "custom_styles")
      end
    end
end
