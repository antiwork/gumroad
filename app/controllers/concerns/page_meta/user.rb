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

    # Only the home page reads the seller's SEO fields; /subscribe and /coffee
    # keep the defaults.
    def profile_home_title(user)
      user.seller_profile.seo_title || user.name_or_username
    end

    def profile_home_meta_description(user)
      user.seller_profile.seo_description || profile_meta_description(user)
    end

    def set_profile_home_seo_meta(user)
      seller_profile = user.seller_profile
      if seller_profile.seo_title
        set_meta_tag(title: seller_profile.seo_title)
        set_meta_tag(property: "og:title", content: seller_profile.seo_title)
      end
      if seller_profile.seo_description
        set_meta_tag(name: "description", content: seller_profile.seo_description)
        set_meta_tag(property: "og:description", content: seller_profile.seo_description)
      end
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
      card.attributes.each { |property, content| set_meta_tag(property:, content:) } if card

      # Only the generated preview reads as "Subscribe to ..."; with an uploaded
      # avatar, or no image at all, the title carries the seller's name instead.
      if user.name.present? && !card&.subscribe_preview?
        set_meta_tag(property: "og:title", content: user.name)
      end

      if user.seller_profile.custom_styles.present?
        set_custom_styles_meta_tag(user.seller_profile)
      end
      set_default_font_preload_meta_tag(user.seller_profile)
    end
end
