# frozen_string_literal: true

class Thumbnail < ApplicationRecord
  include Deletable
  include CdnUrlHelper

  DISPLAY_THUMBNAIL_DIMENSION = 600
  MAX_FILE_SIZE = 5.megabytes
  ALLOW_CONTENT_TYPES = /jpeg|gif|png|jpg/i

  belongs_to :product, class_name: "Link", optional: true

  has_one_attached :file

  before_create :generate_guid
  validate :validate_file

  def validate_file
    return unless alive? && unsplash_url.blank?

    if file.attached?
      if !file.image? || !file.content_type.match?(ALLOW_CONTENT_TYPES)
        errors.add(:base, "Could not process your thumbnail, please try again.")
      elsif file.byte_size > MAX_FILE_SIZE
        errors.add(:base, "Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
      elsif original_width != original_height
        errors.add(:base, "Please upload a square thumbnail.")
      elsif original_width.to_i < DISPLAY_THUMBNAIL_DIMENSION || original_height.to_i < DISPLAY_THUMBNAIL_DIMENSION
        errors.add(:base, "Could not process your thumbnail, please try again.")
      end
    else
      errors.add(:base, "Could not process your thumbnail, please try again.")
    end
  end

  def alive
    alive? ? self : nil
  end

  def url(variant: :default)
    return unsplash_url if unsplash_url.present?
    return unless file.attached?

    # Don't post process for gifs
    return cdn_url_for(file.url) if file.content_type.include?("gif")

    case variant
    when :default
      cdn_url_for(thumbnail_variant.url)
    when :original
      cdn_url_for(file.url)
    else
      cdn_url_for(file.url)
    end
  end

  def thumbnail_variant
    return unless file.attached?

    file.variant(resize_to_limit: [DISPLAY_THUMBNAIL_DIMENSION, DISPLAY_THUMBNAIL_DIMENSION]).processed
  end

  def as_json(*)
    { url:,
      guid:
    }
  end

  private
    def original_width
      return unless file.attached?

      file.metadata["width"]
    end

    def original_height
      return unless file.attached?

      file.metadata["height"]
    end

    def generate_guid
      self.guid ||= SecureRandom.hex
    end
end
