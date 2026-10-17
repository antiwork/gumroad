# frozen_string_literal: true

# The seller's share-card tags, in one place.
#
# Three <head>s serve the same og:image/twitter:image tags for a seller:
#
# - the profile root, through PageMeta::User (set_meta_tag)
# - the profile's custom-HTML wrapper, hand-built in UsersController
# - a slugged page's <head>, hand-built in UserPagesController
#
# Each grew its own copy and then drifted — gp#1548 (the card served on
# twitter:image only) and gp#3690 (slugged pages served no image at all) are
# both that drift. Every site now reads this module instead.
module PageMeta
  module ShareCard
    SOURCE_SUBSCRIBE_PREVIEW = :subscribe_preview
    SOURCE_AVATAR = :avatar

    # A resolved card: which asset is serving as the image, its URL, and the
    # seller name the alt text is built from.
    class Card
      attr_reader :source, :url, :name

      def initialize(source:, url:, name:)
        @source = source
        @url = url
        @name = name
      end

      def subscribe_preview?
        source == SOURCE_SUBSCRIBE_PREVIEW
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
          subscribe_preview? ? name : "#{name}'s profile picture"
        end

        # [property, raw content, HTML content]. One list, so the order and the
        # values cannot differ between the set_meta_tag and hand-built callers.
        def tag_specs
          @tag_specs ||= begin
            url_html = ERB::Util.h(url)
            name_html = ERB::Util.h(name)
            # The possessive suffix is literal, not escaped: it has always
            # rendered that way in the profile wrapper's alt text.
            alt_html = subscribe_preview? ? name_html : "#{name_html}'s profile picture"
            specs = [["og:image", url, url_html]]
            if subscribe_preview?
              # Dimensions + type let Facebook's crawler render the card on the
              # FIRST share after a scrape; without them it processes the image
              # asynchronously and that first preview goes out imageless.
              specs << ["og:image:type", "image/png", "image/png"]
              specs << ["og:image:width", SubscribePreviewGeneratorService::OUTPUT_WIDTH.to_s, SubscribePreviewGeneratorService::OUTPUT_WIDTH.to_s]
              specs << ["og:image:height", SubscribePreviewGeneratorService::OUTPUT_HEIGHT.to_s, SubscribePreviewGeneratorService::OUTPUT_HEIGHT.to_s]
            end
            specs << ["og:image:alt", alt, alt_html]
            if subscribe_preview?
              specs << ["twitter:card", "summary_large_image", "summary_large_image"]
              specs << ["twitter:image", url, url_html]
              specs << ["twitter:image:alt", alt, alt_html]
            end
            specs
          end
        end
    end

    # nil when the seller has neither a generated preview nor an uploaded
    # avatar. avatar_url always resolves — to Gumroad's default avatar — so
    # advertising it without this check would present that placeholder as the
    # seller's share image; with no card the tags are omitted and scrapers fall
    # back to their own.
    def self.for(user)
      if user.subscribe_preview_url.present?
        Card.new(source: SOURCE_SUBSCRIBE_PREVIEW, url: user.subscribe_preview_url, name: user.name_or_username.to_s)
      elsif user.avatar.attached?
        Card.new(source: SOURCE_AVATAR, url: user.avatar_url, name: user.name_or_username.to_s)
      end
    end
  end
end
