# frozen_string_literal: true

class Thumbnail < ApplicationRecord
  include Deletable
  include CdnUrlHelper

  DISPLAY_THUMBNAIL_DIMENSION = 600
  MAX_FILE_SIZE = 5.megabytes
  ALLOW_CONTENT_TYPES = /jpeg|gif|png|jpg/i
  RemoteFileTooLarge = Class.new(StandardError)

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

  def url=(new_url)
    new_url = new_url.to_s
    new_url = "https:#{new_url}" if new_url.starts_with?("//")
    new_url = Addressable::URI.escape(new_url) unless URI::ABS_URI.match?(new_url)
    new_uri = URI.parse(new_url)
    raise URI::InvalidURIError.new("URL '#{new_url}' is not a web url") unless new_uri.scheme.in?(["http", "https"])
    raise URI::InvalidURIError.new("URL must include a valid host") if new_uri.host.blank?
    new_url = new_uri.to_s
    filename = File.basename(new_uri.path)
    filename = "thumbnail" if filename.blank? || filename == "/"

    blob = nil
    tempfile = Tempfile.new(binmode: true)
    begin
      response = SsrfFilter.get(new_url) do |http_response|
        raise RemoteFileTooLarge if http_response["content-length"].to_i > MAX_FILE_SIZE

        write_file = http_response.is_a?(Net::HTTPSuccess)
        response_byte_size = 0
        http_response.read_body do |chunk|
          response_byte_size += chunk.bytesize
          raise RemoteFileTooLarge if response_byte_size > MAX_FILE_SIZE

          tempfile.write(chunk) if write_file
        end
      end
      raise ActiveStorage::FileNotFoundError unless response.is_a?(Net::HTTPSuccess)

      tempfile.rewind
      blob = ActiveStorage::Blob.create_and_upload!(io: tempfile,
                                                    filename: filename,
                                                    content_type: response.content_type)
      blob.analyze
      self.unsplash_url = nil
      file.attach(blob.signed_id)
    rescue
      blob&.purge
      raise
    ensure
      tempfile.close!
    end
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
  rescue MiniMagick::Error, ActiveStorage::Error, Errno::ENOENT => e
    Rails.logger.warn("Thumbnail#url error (#{id}): #{e.class} => #{e.message}")
    cdn_url_for(file.url)
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
