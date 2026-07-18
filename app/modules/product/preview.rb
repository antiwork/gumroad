# frozen_string_literal: true

module Product::Preview
  extend ActiveSupport::Concern

  MAX_PREVIEW_COUNT = 8

  # If the preview height is not defined or too small we will default to this value, this makes sure we display a large enough preview
  # image in the users library
  DEFAULT_MOBILE_PREVIEW_HEIGHT = 204

  included do
    scope :with_asset_preview, -> { joins(:asset_previews).where("asset_previews.deleted_at IS NULL") }
  end

  FILE_REGEX.each do |type, _ext|
    define_method("preview_#{type}_path?") do
      main_preview.present? && ((main_preview.file.attached? && main_preview.file.public_send(:"#{ type }?")) || (type == "image" && main_preview.unsplash_url.present?))
    end
  end

  def main_preview
    display_asset_previews.first
  end
  alias preview main_preview

  def mobile_oembed_url
    OEmbedFinder::MOBILE_URL_REGEXES.detect { |r| preview_oembed_url.try(:match, r) } ? preview_oembed_url : ""
  end

  def preview=(preview)
    return main_preview&.mark_deleted! if preview.blank?

    asset_preview = asset_previews.build
    if preview.is_a?(String) && preview.present?
      asset_preview.url = preview
      asset_preview.save!
    elsif preview.respond_to?(:path)
      asset_preview.file.attach preview
      asset_preview.save!
      asset_preview.file.analyze
    end
  end
  alias preview_url= preview=

  def preview_oembed
    main_preview&.oembed
  end

  def preview_oembed_height
    main_preview&.oembed && main_preview&.height
  end

  def preview_oembed_thumbnail_url
    main_preview&.oembed_thumbnail_url
  end

  def preview_oembed_width
    main_preview&.oembed && main_preview&.width
  end

  def preview_oembed_url
    main_preview&.oembed_url
  end

  def preview_width
    main_preview&.display_width
  end

  def preview_height
    main_preview&.display_height
  end

  def preview_url
    main_preview&.url
  end

  # The image social scrapers (Facebook, iMessage, X, etc.) should use when this
  # product is shared: the cover image when one exists, otherwise the thumbnail
  # of a video/oembed cover. Shared by the standard product page meta tags
  # (PageMeta::Product) and the custom-HTML wrapper document (LinksController)
  # so the two surfaces can't drift apart — the wrapper previously implemented
  # its own og:image logic without these fallbacks, which dropped the image for
  # any product that had a cover but no thumbnail (gumroad-private#1122).
  # Oembed thumbnail URLs come from third-party hosts and can contain characters
  # that are invalid in a URL, so that branch is URI-escaped here; cover URLs
  # and video poster URLs are our own storage/CDN URLs and are returned as-is.
  # For a video file uploaded directly to Gumroad the poster is the ffmpeg
  # frame generated in the background by GenerateVideoPosterWorker — nil until
  # that has run, in which case the share image is simply omitted.
  # (Named without a _url suffix because CONTRIBUTING.md forbids new methods
  # ending in _url/_path — they can collide with Rails route helpers.)
  def social_share_image
    return preview_url if preview_image_path?
    return Addressable::URI.escape(preview_oembed_thumbnail_url) if preview_oembed_thumbnail_url.present?

    main_preview&.video_poster_url
  end

  def preview_width_for_mobile
    preview_width || 0
  end

  def preview_height_for_mobile
    mobile_preview_height = preview_height || 0
    mobile_preview_height = 0 if mobile_preview_height < DEFAULT_MOBILE_PREVIEW_HEIGHT
    mobile_preview_height
  end
end
