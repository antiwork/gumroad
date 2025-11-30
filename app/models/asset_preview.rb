# frozen_string_literal: true

class AssetPreview < ApplicationRecord
  include Deletable
  include CdnUrlHelper

  SUPPORTED_IMAGE_CONTENT_TYPES = /jpeg|gif|png|jpg/i
  DEFAULT_DISPLAY_WIDTH = 670
  RETINA_DISPLAY_WIDTH = (DEFAULT_DISPLAY_WIDTH * 1.5).to_i

  after_commit :invalidate_product_cache
  after_create :reset_moderated_by_iffy_flag

  # Update updated_at of product to regenerate the sitemap in RefreshSitemapMonthlyWorker
  belongs_to :link, touch: true, optional: true
  before_create :generate_guid
  before_create :set_position
  serialize :oembed, coder: YAML
  validate :url_or_file
  validate :height_and_width_presence
  validate :duration_presence_for_video
  validate :max_preview_count, on: :create
  validate :oembed_has_width_and_height
  validate :oembed_url_presence, on: :create, if: -> { oembed.present? }
  validates :link, presence: :true

  delegate :content_type, to: :file, allow_nil: true

  scope :in_order, -> { order(position: :asc, created_at: :asc) }

  has_one_attached :file

  def as_json(*)
    { url:,
      original_url: url(style: :original),
      thumbnail: oembed_thumbnail_url,
      id: guid,
      type: display_type,
      filetype:,
      width: display_width,
      height: display_height,
      native_width: width,
      native_height: height }
  end

  def display_height
    width && height && (height.to_i * (display_width.to_i / width.to_f)).to_i
  end

  def display_width
    width && [DEFAULT_DISPLAY_WIDTH, width].min
  end

  def retina_width
    width && [RETINA_DISPLAY_WIDTH, width].min
  end

  def width
    if file.attached?
      file.blob.metadata[:width]
    else
      oembed_width
    end
  end

  def height
    if file.attached?
      file.blob.metadata[:height]
    else
      oembed_height
    end
  end

  def oembed_width
    oembed && oembed["info"]["width"].to_i
  end

  def oembed_height
    oembed && oembed["info"]["height"].to_i
  end

  def retina_variant
    return unless file.attached?
    file.variant(resize_to_limit: [retina_width, nil]).processed
  end

  def display_type
    return "unsplash" if unsplash_url
    return "oembed" if oembed

    %w[image video].detect { |type| file.public_send(:"#{ type }?") }
  end

  def filetype
    if file.attached?
      from_ext = File.extname(file.filename.to_s).sub(".", "")
      from_ext = file.content_type.split("/").last if from_ext.blank?
      from_ext
    else
      nil
    end
  end

  def generate_guid
    self.guid ||= SecureRandom.hex # For duplicate product, use the original attachment guid to avoid regeneration.
  end

  def oembed_thumbnail_url
    return nil unless oembed

    url = oembed["info"]["thumbnail_url"].to_s.strip
    return nil unless safe_url?(url)

    url
  end

  def oembed_url
    return nil unless oembed

    doc = Nokogiri::HTML(oembed["html"])
    iframe = doc.css("iframe").first
    return nil unless iframe

    url = iframe[:src].strip
    return nil unless safe_url?(url)

    url = "https:#{url}" if url.starts_with?("//")
    url += "&enablejsapi=1" if /youtube.*feature=oembed/.match?(url)
    url += "?api=1" if %r{vimeo.com/video/\d+\z}.match?(url)
    url
  end

  def image_url?
    unsplash_url.present? || (file.attached? && file.image?)
  end

  def url(style: nil)
    return unsplash_url if unsplash_url.present?
    return oembed_url if oembed_url.present?

    return unless file.attached?

    style ||= default_style
    cdn_url_for(url_from_file(style:))
  end

  def url_from_file(style: nil)
    return unless file.attached?

    style ||= default_style

    Rails.cache.fetch("attachment_#{file.id}_#{style}_url") do
      if style == :retina
        retina_variant.url
      else
        file.url
      end
    end
  rescue
    file.url
  end

  def default_style
    should_post_process? ? :retina : :original
  end

  def should_post_process?
    return false unless file.attached?

    file.image? && !file.content_type.include?("gif")
  end

  def url=(new_url)
    new_url = new_url.to_s
    new_url = "https:#{new_url}" if new_url.starts_with?("//")
    new_url = Addressable::URI.escape(new_url) unless URI::ABS_URI.match?(new_url)
    new_uri = URI.parse(new_url)
    raise URI::InvalidURIError.new("URL '#{new_url}' is not a web url") unless new_uri.scheme.in?(["http", "https"])
    new_url = new_uri.to_s
    embeddable = OEmbedFinder.embeddable_from_url(new_url)

    if embeddable
      self.oembed = embeddable.stringify_keys
      file.purge
    else
      self.oembed = nil

      response = SsrfFilter.get(new_url)
      tempfile = Tempfile.new(binmode: true)
      tempfile.write(response.body)
      tempfile.rewind
      blob = ActiveStorage::Blob.create_and_upload!(io: tempfile,
                                                    filename: File.basename(new_url),
                                                    content_type: response.content_type)
      self.file.attach(blob.signed_id)
      self.file.analyze
    end
  end

  def analyze_file
    if file.attached? && !file.analyzed?
      file.analyze
    end
  end

  private
    def set_position
      previous = link.asset_previews.in_order.last
      if previous
        self.position = previous.position.present? ? previous.position + 1 : link.asset_previews.in_order.count
      else
        self.position = 0
      end
    end

    def url_or_file
      return if deleted?

      errors.add(:base, "Could not process your preview, please try again.") unless valid_file_type?
    end

    def max_preview_count
      return if deleted?

      errors.add(:base, "Sorry, we have a limit of #{Link::MAX_PREVIEW_COUNT} previews. Please delete an existing one before adding another.") if link.asset_previews.alive.count >= Link::MAX_PREVIEW_COUNT
    end

    def valid_file_type?
      return true unless file.attached?
      return true if file.video?

      file.image? && content_type.match?(SUPPORTED_IMAGE_CONTENT_TYPES)
    end

    def height_and_width_presence
      return unless file.attached? && file.analyzed?

      if (file.image? || file.video?) && !(file.blob.metadata&.dig(:height) && file.blob.metadata&.dig(:width))
        errors.add(:base, "Could not analyze cover. Please check the uploaded file.")
      end
    end

    def oembed_has_width_and_height
      return if file.attached? || unsplash_url.present?

      unless oembed&.dig("info", "width") && oembed&.dig("info", "height")
        errors.add(:base, "Could not analyze cover. Please check the uploaded file.")
      end
    end

    def oembed_url_presence
      errors.add(:base, "A URL from an unsupported platform was provided. Please try again.") if oembed_url.blank?
    end

    def duration_presence_for_video
      return unless file.attached? && file.analyzed?

      errors.add(:base, "Could not analyze cover. Please check the uploaded file.") if file.video? && !file.blob.metadata&.dig(:duration)
    end

    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end

    def reset_moderated_by_iffy_flag
      link&.update_attribute(:moderated_by_iffy, false)
    end

    def safe_url?(url)
      return false if url.blank?
      return false if url.match?(/\A\s*(?:javascript|data|vbscript|file):/i)

      true
    end
end
