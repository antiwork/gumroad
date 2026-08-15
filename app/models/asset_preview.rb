# frozen_string_literal: true

class AssetPreview < ApplicationRecord
  include Deletable
  include CdnUrlHelper

  SUPPORTED_IMAGE_CONTENT_TYPES = /jpeg|gif|png|jpg/i
  DEFAULT_DISPLAY_WIDTH = 670
  RETINA_DISPLAY_WIDTH = (DEFAULT_DISPLAY_WIDTH * 1.5).to_i

  # Upload limits for image covers. Without them, sellers could upload
  # enormous images (a real case: six 254 MB, 18000x13500px PNGs) and every
  # later page render that needed a resized variant would spend minutes
  # downloading and processing them, blowing the 120-second request timeout
  # and locking the seller out of their own product editor.
  MAX_IMAGE_FILE_SIZE = 50.megabytes
  # Covers render at most RETINA_DISPLAY_WIDTH (1005px) wide, so anything
  # bigger than this is wasted pixels; images above the limit are resized
  # down in the background (see resize_oversized_image!).
  MAX_IMAGE_DIMENSION = 4096

  after_commit :invalidate_product_cache
  # Kick off poster-frame extraction right away so the poster is usually
  # ready by the time anyone views the product page.
  after_create_commit :enqueue_video_poster_generation
  # Shrink too-large image covers in the background so variant generation on
  # later renders stays fast.
  after_create_commit :enqueue_oversized_image_resize
  after_create_commit :enqueue_retina_variant_process

  # Update updated_at of product to regenerate the sitemap in RefreshSitemapMonthlyWorker
  belongs_to :link, touch: true, optional: true
  before_create :generate_guid
  before_create :set_position
  serialize :oembed, coder: YAML
  validate :url_or_file
  validate :height_and_width_presence
  validate :duration_presence_for_video
  validate :max_preview_count, on: :create
  validate :image_file_size_within_limit, on: :create
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
    # A zero width slips past the `width &&` truthiness check (0 is truthy in
    # Ruby) — e.g. an oEmbed provider reporting a non-numeric width like
    # "auto", which `to_i`s to 0. Dividing by 0.0 yields NaN, and NaN.to_i
    # raises FloatDomainError, which used to crash API responses that
    # serialize the product's covers. Treat an unusable width as "no
    # dimensions known" instead.
    return nil unless width.to_i.positive? && height

    (height.to_i * (display_width.to_i / width.to_f)).to_i
  end

  def display_width
    # Same contract as display_height: a missing or non-positive width means
    # "dimensions unknown", serialized as nil rather than a bogus 0.
    return nil unless width.to_i.positive?

    [DEFAULT_DISPLAY_WIDTH, width].min
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

    file.variant(resize_to_limit: [retina_width, nil])
  end

  # Worker-only. `.processed` runs ImageMagick; request paths must not call this.
  def generate_retina_variant!
    return unless file.attached? && should_post_process?

    variant = retina_variant
    return variant.processed.url if variant_processed?(variant)

    url = Timeout.timeout(IMAGE_PROCESSING_TIMEOUT_SECONDS) do
      variant.processed.url
    end
    Rails.cache.write("attachment_#{file.id}_retina_url", url)
    url
  rescue StandardError => e
    # Re-raise so ProcessAssetPreviewRetinaWorker's retries fire on transient failures.
    Rails.logger.warn("AssetPreview#generate_retina_variant! failed for asset_preview #{id}: #{e.message}")
    raise
  end

  # True when the attached image is larger than covers ever render and should
  # be shrunk in the background (see ResizeOversizedAssetPreviewWorker).
  # GIFs are excluded: resizing can break animation, and they skip
  # post-processing everywhere else too (see should_post_process?).
  def oversized_image?
    return false unless file.attached? && file.analyzed?
    return false unless should_post_process?

    width.to_i > MAX_IMAGE_DIMENSION || height.to_i > MAX_IMAGE_DIMENSION
  end

  # Worker-only: download + resize of a huge original blows the request timeout.
  def resize_oversized_image!
    return unless oversized_image?

    # Resize can take a while; the cover may be replaced or deleted. Without
    # this id check we'd attach a resized copy of the OLD image.
    source_blob_id = file.blob.id

    resized = file.variant(resize_to_limit: [MAX_IMAGE_DIMENSION, MAX_IMAGE_DIMENSION]).processed

    # Upload the resized copy to storage BEFORE taking the row lock, so the
    # lock is never held across network I/O.
    resized_blob = resized.blob.open do |tempfile|
      ActiveStorage::Blob.create_and_upload!(
        io: tempfile,
        filename: file.filename,
        content_type: file.content_type
      )
    end

    attached_resized_copy = false
    begin
      # with_lock reloads, so deleted? is current. Also lock the attachment:
      # a write there does not touch this row's lock, so a replace can land
      # between the blob check and attach. Today's replace path creates a new
      # row + mark_deleted! (serialized by with_lock); the attachment lock is
      # defense in depth for a future re-attach-in-place.
      with_lock do
        attachment = ActiveStorage::Attachment.lock.find_by(record: self, name: "file")
        if !deleted? && attachment&.blob_id == source_blob_id
          file.attach(resized_blob)
          attached_resized_copy = true
        end
      end
    ensure
      # Cover changed during resize, or we raised after upload. purge_later so
      # a storage hiccup here cannot mask the exception, and retries don't
      # orphan one blob per attempt.
      resized_blob.purge_later unless attached_resized_copy
    end

    return unless attached_resized_copy

    file.analyze

    # Product page JSON caches the cover URLs and dimensions, so bust it now
    # that they point at the resized copy.
    link&.invalidate_cache
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

  # nil (images, missing ffmpeg, corrupt file) → player stays black.
  def thumbnail_url
    return oembed_thumbnail_url if oembed

    video_poster_url
  end

  # Generation (download + ffmpeg) is off the request path.
  # Production cache is namespaced by deploy REVISION, so a cache-only poster
  # vanishes every deploy. Read: Rails.cache → persisted preview_image
  # (survives deploys) → nil and enqueue. Empty-string sentinel for 1 hour
  # so retries don't re-run ffmpeg on a video it cannot preview.
  FAILED_POSTER_SENTINEL = ""
  FAILED_POSTER_RETRY_INTERVAL = 1.hour

  def video_poster_url
    return nil unless file.attached? && file.video? && file.previewable?

    cached = Rails.cache.read(video_poster_cache_key)
    return cached if cached.present?

    # Cache miss or sentinel: persisted preview only — never generate here.
    persisted = persisted_video_poster_url
    if persisted.present?
      Rails.cache.write(video_poster_cache_key, persisted)
      return persisted
    end

    # Sentinel: ffmpeg already failed; wait for expiry before requeue.
    return nil unless cached.nil?

    GenerateVideoPosterWorker.perform_async(id)
    nil
  end

  # Already-persisted poster URL, or nil. Rescues URL-build failures so a
  # half-written preview cannot 500 a product page.
  #
  # process: true only from a worker. variant.processed generates the resized
  # copy inline; a page of covers would do that once per cover.
  def persisted_video_poster_url(process: false)
    blob = file.blob
    return nil unless blob&.preview_image&.attached?

    variant = blob.preview_image.variant(resize_to_limit: [retina_width || RETINA_DISPLAY_WIDTH, nil])
    return nil unless process || resized_poster_exists?(variant)

    cdn_url_for(variant.processed.url)
  rescue StandardError => e
    Rails.logger.warn("AssetPreview#persisted_video_poster_url failed for asset_preview #{id}: #{e.message}")
    nil
  end

  # Extracts a poster frame, reusing the persisted preview when one already
  # exists instead of re-running ffmpeg. Only called from
  # GenerateVideoPosterWorker.
  def generate_video_poster!
    return nil unless file.attached? && file.video? && file.previewable?

    # Already persisted by an earlier generation (possibly many deploys ago) —
    # reuse it instead of re-downloading the video and re-running ffmpeg. This is
    # what makes the backfill cheap for covers whose preview_image survived even
    # though the cache pointer didn't. We're in a worker, so it's fine to build
    # the resized copy of the poster here if it doesn't exist yet.
    persisted = persisted_video_poster_url(process: true)
    if persisted.present?
      Rails.cache.write(video_poster_cache_key, persisted)
      return persisted
    end

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

    if style == :retina
      variant = retina_variant
      if variant && variant_processed?(variant)
        Rails.cache.fetch("attachment_#{file.id}_retina_url") { variant.url }
      else
        enqueue_retina_variant_process
        file.url
      end
    else
      Rails.cache.fetch("attachment_#{file.id}_#{style}_url") { file.url }
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

    # Lookup, not an image-processing run. false when we can't tell: the caller
    # reports "no poster" and the worker makes the resized copy off-request.
    def variant_processed?(variant)
      return false unless ActiveStorage.track_variants

      variant.blob.variant_records.exists?(variation_digest: variant.variation.digest)
    end
    alias_method :resized_poster_exists?, :variant_processed?

    def enqueue_video_poster_generation
      return unless file.attached? && file.video?

      GenerateVideoPosterWorker.perform_async(id)
    end

    def enqueue_retina_variant_process
      return unless file.attached? && should_post_process?

      ProcessAssetPreviewRetinaWorker.perform_async(id)
    end

    def enqueue_oversized_image_resize
      return unless oversized_image?

      ResizeOversizedAssetPreviewWorker.perform_async(id)
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

    def image_file_size_within_limit
      return if deleted?
      return unless file.attached? && file.image?
      return if file.blob.byte_size.to_i <= MAX_IMAGE_FILE_SIZE

      errors.add(:base, "Cover images must be smaller than #{MAX_IMAGE_FILE_SIZE / 1.megabyte} MB. Please resize or compress the image and try again.")
    end

    def valid_file_type?
      return true unless file.attached?
      return true if file.video?

      file.image? && content_type.match?(SUPPORTED_IMAGE_CONTENT_TYPES)
    end

    def height_and_width_presence
      return unless file.attached? && file.analyzed?

      # Dimensions must be present AND positive. ffprobe/vips report width and
      # height of 0 for files they can identify but not really decode (e.g. a
      # truncated or mislabeled video), and a 0-width cover later produces NaN
      # in display-dimension math, so reject it at upload time like a file we
      # couldn't analyze at all.
      if (file.image? || file.video?) && !(file.blob.metadata&.dig(:height).to_i.positive? && file.blob.metadata&.dig(:width).to_i.positive?)
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
