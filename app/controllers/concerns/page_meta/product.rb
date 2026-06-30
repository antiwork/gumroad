# frozen_string_literal: true

module PageMeta::Product
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    def set_product_page_meta(product)
      product_description = product.description.present? ? product.plaintext_description : "Available on Gumroad"

      set_meta_tag(name: "description", content: product_description)
      set_meta_tag(property: "gr:page:type", content: "product")
      set_meta_tag(property: "product:retailer_item_id", content: product.unique_permalink)
      set_meta_tag(property: "product:price:amount", content: (product.price_cents / 100.0).round(2))
      set_meta_tag(property: "product:price:currency", content: product.price_currency_type.upcase)

      set_open_graph_meta(product, product_description:)

      set_twitter_meta(product, product_description:)

      product.display_asset_previews.select { |asset| asset.file.image? }.each do |asset|
        set_meta_tag(tag_name: "link", rel: "preload", as: "image", href: asset.url)
      end

      set_meta_tag(tag_name: "link", rel: "canonical", href: product.long_url, head_key: "canonical")

      if (structured_data = product.structured_data).any?
        set_meta_tag(tag_name: "script", type: "application/ld+json", inner_content: structured_data, head_key: "structured-data")
      end
    end

    def set_open_graph_meta(product, product_description:)
      set_meta_tag(property: "og:title", content: product.name)
      set_meta_tag(property: "og:description", content: product_description)
      set_meta_tag(property: "og:url", content: product.long_url)

      set_open_graph_image_meta(product)

      set_meta_tag(property: "og:type", content: "#{FACEBOOK_OG_NAMESPACE}:product")
    end

    def set_open_graph_image_meta(product)
      if product.preview_image_path?
        set_meta_tag(property: "og:image", content: product.preview_url)
        set_meta_tag(property: "og:image:alt", content: "")
      elsif product.preview_oembed_thumbnail_url
        set_meta_tag(
          property: "og:image",
          content: Addressable::URI.escape(product.preview_oembed_thumbnail_url).html_safe,
        )
        set_meta_tag(property: "og:image:alt", content: "")
      end
    end

    # Equivalent to `twitter_product_card(product, product_description:).html_safe`
    def set_twitter_meta(product, product_description:)
      set_meta_tag(property: "twitter:title", content: product.name)

      if product.preview_image_path?
        set_meta_tag(property: "twitter:card", content: "summary_large_image")
        set_meta_tag(property: "twitter:image", content: product.preview_url)
        set_meta_tag(property: "twitter:image:alt", content: "")
      elsif product.preview_oembed.present?
        set_meta_tag(property: "twitter:card", content: "player")
        set_meta_tag(property: "twitter:image", content: product.preview_oembed_thumbnail_url)
        set_meta_tag(property: "twitter:player", content: product.preview_oembed_url)
        set_meta_tag(property: "twitter:player:width", content: product.preview_oembed_width)
        set_meta_tag(property: "twitter:player:height", content: product.preview_oembed_height)
      elsif product.preview_video_path?
        set_meta_tag(property: "twitter:card", content: "player")
        set_meta_tag(property: "twitter:image", content: "https://gumroad.com/assets/icon.png")
        set_meta_tag(property: "twitter:player", content: product.preview_url)
        set_meta_tag(property: "twitter:player:width", content: product.preview_width)
        set_meta_tag(property: "twitter:player:height", content: product.preview_height)
      else
        set_meta_tag(property: "twitter:card", content: "summary")
      end

      set_meta_tag(property: "twitter:domain", content: "Gumroad")

      description = if product_description.present?
        product_description
      elsif product.description.present?
        product.plaintext_description
      else
        "Available on Gumroad"
      end
      description = description.length > 200 ? "#{description[0, 197]}..." : description
      set_meta_tag(property: "twitter:description", content: description)

      if product.user&.twitter_handle?
        set_meta_tag(property: "twitter:creator", content: "@#{product.user.twitter_handle}")
      end
    end
end
