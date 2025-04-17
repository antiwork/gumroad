# frozen_string_literal: true

module VideoFile::HasThumbnail
  extend ActiveSupport::Concern

  THUMBNAIL_SUPPORTED_CONTENT_TYPES = /jpeg|gif|png|jpg/i
  THUMBNAIL_MAXIMUM_SIZE = 5.megabytes

  included do
    has_one_attached :thumbnail do |attachable|
      attachable.variant :preview, resize_to_limit: [1280, 720], preprocessed: true
    end

    validate :validate_thumbnail
  end

  def validate_thumbnail
    return unless thumbnail.attached?

    if !thumbnail.image? || !thumbnail.content_type.match?(THUMBNAIL_SUPPORTED_CONTENT_TYPES)
      errors.add(:thumbnail, "must be a JPG, PNG, or GIF image.")
      return
    end

    if thumbnail.byte_size > THUMBNAIL_MAXIMUM_SIZE
      errors.add(:thumbnail, "must be smaller than 5 MB.")
    end
  end

  def thumbnail_url
    return nil unless thumbnail.attached?

    url = thumbnail.variant(:preview).url || thumbnail.url
    url.present? ? cdn_url_for(url) : nil
  end
end
