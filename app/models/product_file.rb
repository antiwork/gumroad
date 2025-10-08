# frozen_string_literal: true

class ProductFile < ApplicationRecord
  include S3Retrievable, WithFileProperties, ExternalId, SignedUrlHelper, JsonData, SendableToKindle, Deletable,
          CdnDeletable, FlagShihTzu, CdnUrlHelper, Streamable

  SUPPORTED_THUMBNAIL_IMAGE_CONTENT_TYPES = /jpeg|gif|png|jpg/i
  MAXIMUM_THUMBNAIL_FILE_SIZE = 5.megabytes

  has_paper_trail

  belongs_to :link, optional: true
  belongs_to :folder, class_name: "ProductFolder", optional: true
  belongs_to :installment, optional: true

  has_many :stamped_pdfs
  has_many :alive_stamped_pdfs, -> { alive }, class_name: "StampedPdf"
  has_many :subtitle_files
  has_many :alive_subtitle_files, -> { alive }, class_name: "SubtitleFile"
  has_many :media_locations
  has_one :dropbox_file
  has_and_belongs_to_many :base_variants
  has_and_belongs_to_many :product_files_archives

  has_one_attached :thumbnail

  normalizes :isbn, with: ->(value) do
    next if value.blank?

    value.strip.upcase.gsub(/[\s–—−]/, "-")
  end

  before_save :set_filegroup
  before_save :downcase_filetype
  after_commit :schedule_file_analyze, on: :create
  after_commit :stamp_existing_pdfs_if_needed, on: :update
  after_create :reset_moderated_by_iffy_flag

  has_flags 1 => :is_transcoded_for_hls,
            2 => :is_linked_to_existing_file,
            3 => :analyze_completed,
            4 => :stream_only,
            5 => :pdf_stamp_enabled,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  validates_presence_of :url
  validates :isbn, isbn: true, allow_nil: true, if: :supports_isbn?
  validates :isbn, absence: { unless: :supports_isbn? }

  validate :valid_url?, on: :create
  validate :belongs_to_product_or_installment, on: :save
  validate :thumbnail_is_vaild

  after_save :invalidate_product_cache
  after_commit :schedule_rename_in_storage, on: :update, if: :saved_change_to_display_name?

  attr_json_data_accessor :epub_section_info
  has_s3_fields :url

  scope :in_order, -> { order(position: :asc) }
  scope :ordered_by_ids, ->(ids) { reorder([Arel.sql("FIELD(product_files.id, ?)"), ids]) }
  scope :pdf, -> { where(filetype: "pdf") }
  scope :not_external_link, -> { where.not(filetype: "link") }
  scope :archivable, -> { not_external_link.not_stream_only }

  def has_alive_duplicate_files?
    ProductFile.alive.where(url:).exists?
  end

  def has_cdn_url?
    url&.starts_with?(S3_BASE_URL)
  end

  def has_valid_external_link?
    url =~ /\A#{URI::DEFAULT_PARSER.make_regexp}\z/ && URI.parse(url).host.present?
  end

  def valid_url?
    if external_link? && !has_valid_external_link?
      errors.add(:base, "#{url} is not a valid URL.")
    elsif !external_link? && !has_cdn_url?
      errors.add(:base, "Please provide a valid file URL.")
    end
  end

  def as_json(options = {})
    url_for_thumbnail = thumbnail_url
    {
      # TODO (product_edit_react) remove duplicate attribute
      file_name: name_displayable,
      display_name: name_displayable,
      description:,
      extension: display_extension,
      file_size: size,
      pagelength: (epub? ? nil : pagelength),
      duration:,
      is_pdf: pdf?,
      pdf_stamp_enabled: pdf_stamp_enabled?,
      is_streamable: streamable?,
      stream_only: stream_only?,
      is_transcoding_in_progress: options[:existing_product_file] ? false : transcoding_in_progress?,
      id: external_id,
      attached_product_name: link.try(:name),
      subtitle_files: alive_subtitle_files.map do |file|
        {
          url: file.url,
          file_name: file.s3_display_name,
          extension: file.s3_display_extension,
          language: file.language,
          file_size: file.size,
          size: file.size_displayable,
          signed_url: signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename, is_video: true),
          status: { type: "saved" },
        }
      end,
      url:,
      thumbnail: url_for_thumbnail.present? ? { url: url_for_thumbnail, signed_id: thumbnail.signed_id, status: { type: "saved" } } : nil,
      status: { type: "saved" },
    }
  end

  delegate :user, to: :with_product_files_owner

  def with_product_files_owner
    link || installment
  end

  def must_be_pdf_stamped?
    pdf? && pdf_stamp_enabled?
  end

  def epub?
    filetype == "epub"
  end

  def pdf?
    filetype == "pdf"
  end

  def mobi?
    filetype == "mobi"
  end

  def supports_isbn?
    epub? || pdf? || mobi?
  end

  def streamable?
    filegroup == "video"
  end

  def listenable?
    filegroup == "audio"
  end

  def external_link?
    filetype == "link"
  end

  def readable?
    pdf?
  end

  def stream_only?
    streamable? && stream_only
  end

  def archivable?
    !external_link? && !stream_only?
  end

  def consumable?
    streamable? || listenable? || readable?
  end

  def can_send_to_kindle?
    return false if !pdf? && !epub?
    return false if size.nil?

    size < Link::MAX_ALLOWED_FILE_SIZE_FOR_SEND_TO_KINDLE
  end

  def transcoding_failed
    ContactingCreatorMailer.video_transcode_failed(id).deliver_later
  end

  def save_subtitle_files!(files)
    subtitle_files.alive.each do |file|
      found = files.extract! { _1[:url] == file.url }.first
      if found
        file.language = found[:language]
      else
        file.mark_deleted
      end
      file.save!
    end
    files.each { subtitle_files.create!(_1) }
  end

  def delete_all_subtitle_files!
    subtitle_files.alive.each do |file|
      file.mark_deleted
      file.save!
    end
  end

  def delete!
    mark_deleted!
    delete_all_subtitle_files!
  end

  def display_extension
    external_link? ? "URL" : s3_display_extension
  end

  def rename_in_storage
    return if display_name == s3_display_name

    extension = s3_extension
    name_with_extension = display_name.ends_with?(extension) ? display_name : "#{display_name}#{extension}"
    new_key = MultipartTransfer.transfer_to_s3(self.s3_object.presigned_url(:get, expires_in: SignedUrlHelper::SIGNED_S3_URL_VALID_FOR_MAXIMUM.to_i).to_s, destination_filename: name_with_extension, existing_s3_object: self.s3_object)
    self.url = URI::DEFAULT_PARSER.unescape("https://s3.amazonaws.com/#{S3_BUCKET}/#{new_key}")
    save!
  end

  def name_displayable
    return display_name if display_name.present?

    return url if external_link?

    s3_display_name
  end

  def subtitle_files_urls
    subtitle_files.alive.map do |file|
      {
        file: signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename, is_video: true),
        label: file.language,
        kind: "captions"
      }
    end
  end

  def subtitle_files_for_mobile
    subtitle_files.alive.map do |file|
      {
        url: signed_download_url_for_s3_key_and_filename(file.s3_key, file.s3_filename, is_video: true),
        language: file.language
      }
    end
  end

  def mobile_json_data
    {
      name: s3_filename,
      size:,
      filetype:,
      filegroup:,
      id: external_id,
      created_at:,
      name_displayable:,
      description:,
      pagelength: (epub? ? nil : pagelength),
      duration:,
    }
  end

  def read_consumption_markers
    markers = Array.new(pagelength, "")
    if pdf?
      (1..pagelength).each do |page_number|
        # markers is 0-based; page_number is 1-based:
        markers[page_number - 1] = "Page #{page_number}"
      end
    elsif epub?
      markers = epub_section_info.values.map { |epub_section_info_hash| epub_section_info_hash["section_name"] }
    end

    markers
  end

  def schedule_file_analyze
    AnalyzeFileWorker.perform_in(5.seconds, id, self.class.name) unless external_link?
  end

  def queue_for_transcoding?
    streamable? && analyze_completed?
  end

  def latest_media_location_for(purchase)
    return nil if link.nil? || installment.present? || purchase.nil?
    latest_media_location = media_locations.where(purchase_id: purchase.id).order("consumed_at").last

    latest_media_location.as_json
  end

  def content_length
    (listenable? || streamable?) ? duration : pagelength
  end

  def external_folder_id
    ObfuscateIds.encrypt(folder_id) if folder&.alive?
  end

  def thumbnail_url
    return unless streamable?
    return unless thumbnail.attached?

    cached_variant_url = Rails.cache.fetch("attachment_product_file_thumbnail_#{thumbnail.id}_variant_url") { thumbnail_variant.url }
    cdn_url_for(cached_variant_url)
  rescue => e
    Rails.logger.warn("ProductFile#thumbnail_url error (#{id}): #{e.class} => #{e.message}")
    cdn_url_for(thumbnail.url)
  end

  def thumbnail_variant
    return unless thumbnail.attached?
    return unless thumbnail.image? && thumbnail.content_type.match?(SUPPORTED_THUMBNAIL_IMAGE_CONTENT_TYPES)

    thumbnail.variant(resize_to_limit: [1280, 720]).processed
  end

  def cannot_be_stamped?
    # The column allows nil values
    stampable_pdf == false
  end

  private
    def schedule_rename_in_storage
      return if external_link?
      # a slight delay to allow the new `display_name` to propagate to replica DBs
      RenameProductFileWorker.perform_in(5.seconds, id)
    end

    def belongs_to_product_or_installment
      return if (link.present? && installment.nil?) || (link.nil? && installment.present?)

      errors.add(:base, "A file needs to either belong to a product or an installment")
    end

    def set_filegroup
      if filetype == "link"
        self.filegroup = "link"
        return
      end

      determine_and_set_filegroup(s3_extension.delete("."))
    end

    def downcase_filetype
      self.filetype = filetype.downcase if filetype.present?
    end

    def invalidate_product_cache
      link.invalidate_cache if link.present?
    end

    def thumbnail_is_vaild
      return unless thumbnail.attached?

      unless thumbnail.image? && thumbnail.content_type.match?(SUPPORTED_THUMBNAIL_IMAGE_CONTENT_TYPES)
        errors.add(:base, "Please upload a thumbnail in JPG, PNG, or GIF format.")
        return
      end

      if thumbnail.byte_size > MAXIMUM_THUMBNAIL_FILE_SIZE
        errors.add(:base, "Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
      end
    end

    def reset_moderated_by_iffy_flag
      return unless filegroup == "image"
      link&.update_attribute(:moderated_by_iffy, false)
    end

    def stamp_existing_pdfs_if_needed
      return if link.nil?
      return unless saved_change_to_pdf_stamp_enabled? && pdf_stamp_enabled?

      link.sales.successful_gift_or_nongift.not_is_gift_sender_purchase.not_recurring_charge.includes(:url_redirect).find_each(order: :desc) do |purchase|
        next if purchase.url_redirect.blank?
        StampPdfForPurchaseJob.perform_async(purchase.id)
      end
    end

    def video_file_analysis_completed
      if installment&.published?
        transcode_video(self)
      elsif link&.alive?
        if link.auto_transcode_videos?
          transcode_video(self)
        else
          link.enable_transcode_videos_on_purchase!
        end
      end
    end
end
