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

  def preview_width_for_mobile
    preview_width || 0
  end

  def preview_height_for_mobile
    mobile_preview_height = preview_height || 0
    mobile_preview_height = 0 if mobile_preview_height < DEFAULT_MOBILE_PREVIEW_HEIGHT
    mobile_preview_height
  end
end
