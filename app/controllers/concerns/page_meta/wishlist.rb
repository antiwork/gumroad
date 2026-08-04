# frozen_string_literal: true

module PageMeta::Wishlist
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    def set_wishlist_page_meta(wishlist)
      canonical_url = Rails.application.routes.url_helpers.wishlist_url(
        wishlist.url_slug, host: wishlist.user.subdomain_with_protocol
      )
      description = wishlist_meta_description(wishlist)

      set_meta_tag(title: "#{wishlist.name} — curated digital products | Gumroad")
      set_meta_tag(name: "description", content: description)
      set_meta_tag(property: "og:title", content: wishlist.name)
      set_meta_tag(property: "og:description", content: description)
      set_meta_tag(property: "og:url", content: canonical_url)
      set_meta_tag(property: "og:type", content: "website")
      set_meta_tag(tag_name: "link", rel: "canonical", href: canonical_url, head_key: "canonical")

      # The robots gate keeps thin or non-discoverable wishlists (see
      # Wishlist#seo_indexable?) out of the index without hiding the page itself.
      if wishlist.seo_indexable?
        set_meta_tag(name: "robots", content: "index,follow")

        if (structured_data = wishlist.structured_data).any?
          set_meta_tag(tag_name: "script", type: "application/ld+json", inner_content: structured_data, head_key: "structured-data")
        end
      else
        set_meta_tag(name: "robots", content: "noindex")
      end
    end

    def wishlist_meta_description(wishlist)
      return wishlist.description.squish.truncate(160) if wishlist.description.present?

      product_count = wishlist.alive_wishlist_products.size
      "#{wishlist.name} — a wishlist of #{product_count} #{"digital product".pluralize(product_count)} curated by #{wishlist.user.name_or_username} on Gumroad."
    end
end
