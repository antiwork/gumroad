# frozen_string_literal: true

module PageMeta::User
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    # The custom-HTML profile wrapper builds its own <head> and can't use
    # set_meta_tag, so both render sites read this to stay in sync.
    def profile_meta_description(user)
      return user.bio.squish.first(300) if user.bio.present?

      "Get the latest products and updates from #{user.name_or_username} on Gumroad."
    end

    def set_user_page_meta(user)
      set_meta_tag(property: "og:site_name", content: "Gumroad")
      set_meta_tag(property: "og:type", content: "website")

      if user.bio.present?
        title = "Subscribe to #{user.name_or_username} on Gumroad"
      else
        title = "Subscribe to #{user.name_or_username}"
      end
      description = profile_meta_description(user)
      set_meta_tag(property: "og:title", content: title)
      set_meta_tag(name: "description", content: description)
      set_meta_tag(property: "og:description", content: description)

      card = PageMeta::ShareCard.for(user)
      if card
        # The chain and the tag list live in PageMeta::ShareCard, shared with the
        # two hand-built <head>s so the three surfaces cannot drift (gp#1548).
        card.attributes.each { |property, content| set_meta_tag(property:, content:) }
      elsif user.name.present?
        # No share image to announce, so the card title carries the seller's
        # name instead of the "Subscribe to ..." phrasing set above.
        set_meta_tag(property: "og:title", content: user.name)
      end

      if user.seller_profile.custom_styles.present?
        set_custom_styles_meta_tag(user.seller_profile)
      end
      set_default_font_preload_meta_tag(user.seller_profile)
    end
end
