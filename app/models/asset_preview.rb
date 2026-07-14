# frozen_string_literal: true

class AssetPreview < ApplicationRecord
  include Deletable
  include CdnUrlHelper

  SUPPORTED_IMAGE_CONTENT_TYPES = /jpeg|gif|png|jpg/i
  DEFAULT_DISPLAY_WIDTH = 670
  RETINA_DISPLAY_WIDTH = (DEFAULT_DISPLAY_WIDTH * 1.5).to_i

  after_commit :invalidate_product_cache
  # Kick off poster-frame extraction right away so the poster is usually
  # ready by the time anyone views the product page.
  after_create_commit :enqueue_video_poster_generation

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
      thumbnail: thumbnail_url,
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

  IMAGE_PROCESSING_TIMEOUT_SECONDS = 30

  def retina_variant
    return unless file.attached?
    Timeout.timeout(IMAGE_PROCESSING_TIMEOUT_SECONDS) do
      file.variant(resize_to_limit: [retina_width, nil]).processed
    end
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

  # A still image to show for this cover before playback starts.
  # For embedded players (YouTube/Vimeo) this is the thumbnail the platform
  # provides via oEmbed. For video files uploaded directly to Gumroad we ask
  # ActiveStorage for a preview — a frame ffmpeg extracts from the video — so
  # the product page can show that frame instead of a black rectangle while
  # the player is idle. Returns nil for images (they don't need a poster) and
  # when no preview can be generated (e.g. ffmpeg missing or a corrupt file);
  # the player then falls back to the old black idle state.
  def thumbnail_url
    return oembed_thumbnail_url if oembed

    video_poster_url
  end

  # Generating a poster means downloading the video and running ffmpeg, which
  # can take a while for large files. That work never happens on a web
  # request thread: GenerateVideoPosterWorker is enqueued when the cover is
  # created and does the generation in the background, writing the result to
  # the cache. Renders only ever read the cache.
  #   - success caches the poster URL;
  #   - failure caches an empty-string sentinel (for an hour) so the worker's
  #     retries don't re-download and re-run ffmpeg on a video that can't be
  #     previewed.
  # If a render happens before the worker has finished (or for covers created
  # before this existed), this returns nil — the player shows its plain idle
  # state — and we enqueue a generation so the poster appears on later views.
  FAILED_POSTER_SENTINEL = ""
  FAILED_POSTER_RETRY_INTERVAL = 1.hour

  def video_poster_url
    return nil unless file.attached? && file.video? && file.previewable?

    cached = Rails.cache.read(video_poster_cache_key)
    if cached.nil?
      # Nothing generated yet — covers created before poster support existed
      # land here. Kick off a background generation so the poster shows up on
      # subsequent views; this view renders without one.
      GenerateVideoPosterWorker.perform_async(id)
      return nil
    end

    cached == FAILED_POSTER_SENTINEL ? nil : cached
  end

  # Does the actual download + ffmpeg frame extraction. Only called from
  # GenerateVideoPosterWorker — web requests read the cached result via
  # video_poster_url above.
  def generate_video_poster!
    return nil unless file.attached? && file.video? && file.previewable?

    cached = Rails.cache.read(video_poster_cache_key)
    return (cached == FAILED_POSTER_SENTINEL ? nil : cached) unless cached.nil?

    url = Timeout.timeout(IMAGE_PROCESSING_TIMEOUT_SECONDS) do
      preview = file.preview(resize_to_limit: [retina_width || RETINA_DISPLAY_WIDTH, nil]).processed
      cdn_url_for(preview.url)
    end
    Rails.cache.write(video_poster_cache_key, url)
    url
  rescue StandardError => e
    # A missing poster only costs us the nicety of a preview frame, so never
    # let generation raise out of the worker into endless retries. Remember
    # the failure for a while, and log so we can spot systemic failures
    # (e.g. ffmpeg misconfigured on a box).
    Rails.cache.write(video_poster_cache_key, FAILED_POSTER_SENTINEL, expires_in: FAILED_POSTER_RETRY_INTERVAL)
    Rails.logger.warn("AssetPreview#generate_video_poster! failed for asset_preview #{id}: #{e.message}")
    nil
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
    raise URI::InvalidURIError.new("URL must include a valid host") if new_uri.host.blank?
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
    def video_poster_cache_key
      "attachment_#{file.id}_poster_url"
    end

    def enqueue_video_poster_generation
      return unless file.attached? && file.video?

      GenerateVideoPosterWorker.perform_async(id)
    end

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

      errors.add(:base, "Cover must be an image (JPEG, PNG, GIF) or a video.") unless valid_file_type?
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

    def safe_url?(url)
      return false if url.blank?
      return false if url.match?(/\A\s*(?:javascript|data|vbscript|file):/i)

      true
    end
end
