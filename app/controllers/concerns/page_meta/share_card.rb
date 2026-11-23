# frozen_string_literal: true

# The seller's share-card tags, in one place: the chain that resolves the image
# and the ordered tag list. The raw values and the HTML are both derived from
# that one list, so the set_meta_tag callers and the hand-built <head>s cannot
# serve different tags for the same seller.
module PageMeta
  module ShareCard
    SOURCE_SHARE_IMAGE = :share_image
    SOURCE_SUBSCRIBE_PREVIEW = :subscribe_preview
    SOURCE_AVATAR = :avatar

    # A resolved card: which asset is serving as the image, its URL, and the
    # seller name the alt text is built from. `image_type` is set only when the
    # content type is known — the seller's own upload — and left nil otherwise.
    class Card
      attr_reader :source, :url, :name, :image_type

      def initialize(source:, url:, name:, image_type: nil)
        @source = source
        @url = url
        @name = name
        @image_type = image_type
      end

      def subscribe_preview?
        source == SOURCE_SUBSCRIBE_PREVIEW
      end

      def avatar?
        source == SOURCE_AVATAR
      end

      # Raw values, for set_meta_tag callers.
      def attributes
        tag_specs.map { |property, raw, _html| [property, raw] }
      end

      # The same tags as HTML, for the hand-built <head>s.
      def to_html
        tag_specs.map { |property, _raw, html| %(<meta property="#{property}" content="#{html}">) }.join("\n")
      end

      private
        def alt
          avatar? ? "#{name}'s profile picture" : name
        end

        # [property, raw content, HTML content]. One list, so the order and the
        # values cannot differ between the set_meta_tag and hand-built callers.
        def tag_specs
          @tag_specs ||= begin
            url_html = ERB::Util.h(url)
            name_html = ERB::Util.h(name)
            # Escape the name only — escaping the whole string would turn the
            # literal possessive suffix into an HTML entity.
            alt_html = avatar? ? "#{name_html}'s profile picture" : name_html
            specs = [["og:image", url, url_html]]
            # Dimensions + type let Facebook's crawler render the card on the
            # FIRST share after a scrape; without them it processes the image
            # asynchronously and that first preview goes out imageless. Only the
            # generated card has known dimensions, so the seller's own upload
            # advertises just the type we can read off the blob.
            if subscribe_preview?
              specs << ["og:image:type", "image/png", "image/png"]
              specs << ["og:image:width", SubscribePreviewGeneratorService::OUTPUT_WIDTH.to_s, SubscribePreviewGeneratorService::OUTPUT_WIDTH.to_s]
              specs << ["og:image:height", SubscribePreviewGeneratorService::OUTPUT_HEIGHT.to_s, SubscribePreviewGeneratorService::OUTPUT_HEIGHT.to_s]
            elsif image_type.present?
              specs << ["og:image:type", image_type, image_type]
            end
            specs << ["og:image:alt", alt, alt_html]
            # An avatar is a small square: announcing it as a summary_large_image
            # would have every client upscale it. The generated card and the
            # seller's own upload, whatever its shape, are meant as large cards.
            unless avatar?
              specs << ["twitter:card", "summary_large_image", "summary_large_image"]
              specs << ["twitter:image", url, url_html]
              specs << ["twitter:image:alt", alt, alt_html]
            end
            specs
          end
        end
    end

    # nil when the seller has neither a share image, a generated preview, nor an
    # avatar: avatar_url always resolves — to Gumroad's default avatar — so
    # announcing it would present that placeholder as the seller's share image.
    # With no card the tags are omitted and scrapers use their own fallback.
    def self.for(user)
      seller_profile = user.seller_profile
      share_image_url = seller_profile.share_image_url
      if share_image_url.present?
        Card.new(source: SOURCE_SHARE_IMAGE, url: share_image_url, name: user.name_or_username.to_s,
                 image_type: seller_profile.share_image.content_type.presence)
      elsif user.subscribe_preview_url.present?
        Card.new(source: SOURCE_SUBSCRIBE_PREVIEW, url: user.subscribe_preview_url, name: user.name_or_username.to_s)
      elsif user.avatar.attached?
        Card.new(source: SOURCE_AVATAR, url: user.avatar_url, name: user.name_or_username.to_s)
      end
    end
  end
end
