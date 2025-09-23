# frozen_string_literal: true

class UrlRedirect < ApplicationRecord
  include ExternalId
  include SignedUrlHelper
  include FlagShihTzu

  # Note: SendPostBlastEmailsJob bypasses all validations and callbacks when creating records.
  before_validation :set_token
  validates :token, uniqueness: { case_sensitive: true }, presence: true
  belongs_to :purchase, optional: true
  belongs_to :link, optional: true
  belongs_to :installment, optional: true
  belongs_to :subscription, optional: true
  belongs_to :preorder, optional: true
  belongs_to :imported_customer, optional: true
  has_many :stamped_pdfs
  has_many :alive_stamped_pdfs, -> { alive }, class_name: "StampedPdf"

  delegate :rental_expired?, to: :purchase, allow_nil: true

  has_flags 1 => :has_been_seen,
            2 => :admin_generated,
            3 => :is_rental,
            4 => :is_done_pdf_stamping,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  TIME_TO_WATCH_RENTED_PRODUCT_AFTER_PURCHASE = 30.days
  TIME_TO_WATCH_RENTED_PRODUCT_AFTER_FIRST_PLAY = 72.hours
  FAKE_VIDEO_URL_GUID_FOR_OBFUSCATION = "ef64f2fef0d6c776a337050020423fc0"
  GUID_GETTER_FROM_S3_URL_REGEX = %r{attachments/(.*)/original}

  # Public: If one exists, returns the product that this UrlRedirect is associated to, directly or indirectly. Otherwise nil is returned.
  def referenced_link
    if purchase.present?
      purchase.link
    elsif imported_customer.present?
      imported_customer.link
    elsif link.present?
      link
    elsif installment.present?
      installment.link
    end
  end

  # Public: Returns the WithProductFiles object that has the content that this UrlRedirect is responsible for delivering.
  def with_product_files
    return installment if installment.present? && installment.has_files?

    return purchase.variant_attributes.order(deleted_at: :asc).first if has_purchased_variants_from_categories_with_files? || has_purchased_variants_from_categories_with_rich_content?

    referenced_link
  end

  def rich_content_json
    json = rich_content_provider&.rich_content_json

    commission = purchase&.commission
    if commission&.is_completed?
      json ||= []
      json << (
        {
          id: "",
          page_id: "",
          title: "Downloads",
          variant_id: nil,
          description: {
            type: "doc",
            content: commission.files.map do |file|
              {
                type: "fileEmbed",
                attrs: {
                  id: file.signed_id,
                }
              }
            end,
          },
          updated_at: commission.updated_at,
        }
      )
    end

    json
  end

  def has_embedded_posts?
    rich_content_provider&.alive_rich_contents&.any?(&:has_posts?) || false
  end

  def entity_archive
    return if with_product_files.has_stampable_pdfs?

    product_files_archives.latest_ready_entity_archive
  end

  def folder_archive(folder_id)
    return if with_product_files.has_stampable_pdfs?

    product_files_archives.latest_ready_folder_archive(folder_id)
  end

  def alive_product_files
    return @cached_alive_product_files if @cached_alive_product_files

    @cached_alive_product_files =
      if installment.present? && installment.has_files?
        installment.product_files.alive.in_order
      elsif rich_content_provider.present?
        rich_content_provider.product_files.alive.ordered_by_ids(rich_content_provider.alive_rich_contents.flat_map(&:embedded_product_file_ids_in_order))
      elsif purchase.present? && has_purchased_variants_from_categories_with_files?
        file_ids = purchase.variant_attributes.reduce([]) do |all_file_ids, version_option|
          all_file_ids + version_option.product_files.alive.pluck(:id)
        end.uniq
        ProductFile.where(id: file_ids).in_order
      else
        referenced_link.product_files.alive.in_order
      end

    @cached_alive_product_files
  end

  def product_files_archives
    @_cached_product_files_archives ||= (rich_content_provider.presence || with_product_files).product_files_archives
  end

  # Public: used to pass the list of downloadable files to Dropbox.
  def product_files_hash
    alive_product_files.map do |product_file|
      next if product_file.stream_only?

      {
        url: signed_location_for_file(product_file),
        filename: product_file.s3_filename
      }
    end.compact.to_json
  end

  def seller
    with_product_files.user
  end

  def redirect_or_s3_location
    if preorder.present?
      signed_download_url_for_s3_key_and_filename(preorder.preorder_link.s3_key, preorder.preorder_link.s3_filename)
    elsif alive_product_files.count == 1
      signed_location_for_file(alive_product_files.first)
    else
      download_page_url
    end
  end

  def signed_location_for_file(product_file)
    return product_file.url if product_file.external_link?
    s3_retrievable = product_file
    if product_file.must_be_pdf_stamped?
      stamped_s3_retrievable = alive_stamped_pdfs.where(product_file_id: product_file.id).first
      s3_retrievable = stamped_s3_retrievable if stamped_s3_retrievable.present?
    end
    s3_key = s3_retrievable.s3_key
    s3_filename = s3_retrievable.s3_filename
    signed_download_url_for_s3_key_and_filename(s3_key, s3_filename, is_video: product_file.streamable?)
  end

  def product_file(product_file_external_id)
    alive_product_files.find_by_external_id(product_file_external_id) if product_file_external_id.present?
  end

  def missing_stamped_pdf?(product_file)
    !alive_stamped_pdfs.where(product_file_id: product_file.id).exists?
  end

  def url
    "#{PROTOCOL}://#{DOMAIN}/r/#{token}"
  end

  def download_page_url
    "#{PROTOCOL}://#{DOMAIN}/d/#{token}"
  end

  def read_url
    "#{PROTOCOL}://#{DOMAIN}/read/#{token}"
  end

  def stream_url
    "#{PROTOCOL}://#{DOMAIN}/s/#{token}"
  end

  def mark_as_seen
    self.has_been_seen = true
    save!
  end

  def mark_unseen
    self.has_been_seen = false
    save!
  end

  def smil_xml_for_product_file(product_file)
    smil_xml = ::Builder::XmlMarkup.new

    smil_xml.smil do |smil|
      smil.body do |body|
        body.switch do |switch|
          s3_path = product_file.s3_key
          switch.video(src: signed_cloudfront_url(s3_path, is_video: true))
        end
      end
    end
  end

  def video_files_playlist(initial_product_file)
    video_files_playlist = { playlist: [], index_to_play: 0 }

    alive_product_files.each do |product_file|
      next unless product_file.streamable?

      video_url, guid = html5_video_url_and_guid_for_product_file(product_file)
      video_data = { sources: [hls_playlist_or_smil_xml_path(product_file), video_url] }
      video_data[:guid] = guid
      video_data[:title] = product_file.name_displayable
      video_data[:tracks] = product_file.subtitle_files_urls
      video_data[:external_id] = product_file.try(:external_id)
      video_data[:latest_media_location] = product_file.latest_media_location_for(purchase)
      video_data[:content_length] = product_file.content_length

      video_files_playlist[:playlist] << video_data
      video_files_playlist[:index_to_play] = video_files_playlist[:playlist].size.pred if product_file == initial_product_file
    end
    video_files_playlist
  end

  def html5_video_url_and_guid_for_product_file(product_file)
    video_url = signed_video_url(product_file)

    # We replace the GUID of the video URL with a fake guid and put the resulting URL in the DOM, along with the real GUID.
    # On the client-side we do the opposite replacement and generate the real URL in js and pass that to JWPlayer.
    # This way we won't have the signed URL for the video file in the DOM. This simply makes it somewhat harder to download the video file.
    guid = video_url[GUID_GETTER_FROM_S3_URL_REGEX, 1]
    [video_url.sub(guid, FAKE_VIDEO_URL_GUID_FOR_OBFUSCATION), guid]
  end

  def hls_playlist_or_smil_xml_path(product_file)
    path_method = if product_file.is_transcoded_for_hls
      :hls_playlist_for_product_file_path
    else
      :url_redirect_smil_for_product_file_path
    end
    Rails.application.routes.url_helpers.public_send(path_method, token, product_file.external_id)
  end

  def signed_video_url(s3_retrievable)
    signed_download_url_for_s3_key_and_filename(s3_retrievable.s3_key, s3_retrievable.s3_filename, is_video: true)
  end

  def product_json_data
    result = referenced_link.as_json(mobile: true).merge(url_redirect_external_id: external_id, url_redirect_token: token)
    result[:file_data] = product_file_json_data_for_mobile unless purchase.present? && purchase.subscription.present? && !purchase.subscription.alive?
    purchase = self.purchase
    if purchase
      result[:purchase_id] = purchase.external_id
      result[:purchased_at] = purchase.created_at
      result[:user_id] = purchase.purchaser.external_id if purchase.purchaser
      result[:product_updates_data] = purchase.update_json_data_for_mobile
      result[:is_archived] = purchase.is_archived
      result[:custom_delivery_url] = nil # Deprecated
    end
    result
  end

  def product_unique_permalink
    referenced_link.unique_permalink
  end

  def is_file_downloadable?(product_file)
    return false if product_file.external_link?
    return false if product_file.stream_only?
    return false if product_file.streamable? && is_rental

    true
  end

  def mark_rental_as_viewed!
    update!(rental_first_viewed_at: Time.current) if is_rental && rental_first_viewed_at.nil?
  end

  # Mobile specific methods

  def product_file_json_data_for_mobile
    alive_product_files.map do |file|
      mobile_product_file_json_data(file)
    end
  end

  def mobile_product_file_json_data(file)
    product_file_mobile_json_data = file.mobile_json_data
    if is_file_downloadable?(file)
      download_url = Rails.application.routes.url_helpers.api_mobile_download_product_file_url(token,
                                                                                               file.external_id,
                                                                                               host: UrlService.api_domain_with_protocol)
      download_url += "?mobile_token=#{Api::Mobile::BaseController::MOBILE_TOKEN}"
      product_file_mobile_json_data[:download_url] = download_url
    end
    product_file_mobile_json_data[:latest_media_location] = file.latest_media_location_for(purchase)
    product_file_mobile_json_data[:content_length] = file.content_length
    product_file_mobile_json_data[:streaming_url] = Rails.application.routes.url_helpers.api_mobile_stream_video_url(token, file.external_id, host: UrlService.api_domain_with_protocol) if file.streamable?
    product_file_mobile_json_data[:external_link_url] = file.url if file.external_link?
    product_file_mobile_json_data
  end

  def self.generate_new_token
    SecureRandom.hex
  end

  def enqueue_job_to_regenerate_deleted_stamped_pdfs
    return if purchase.blank?

    stampable_files = alive_product_files.pdf_stamp_enabled.pluck(:id)
    return if stampable_files.empty?

    stamped_files = alive_stamped_pdfs.pluck(:product_file_id)
    missing = stampable_files - stamped_files
    return if missing.empty?

    deleted = stamped_pdfs.deleted.distinct.pluck(:product_file_id)
    missing_because_deleted = missing & deleted
    return if missing_because_deleted.empty?

    Rails.logger.info("[url_redirect=#{id}, purchase=#{purchase_id}] Stamped PDFs for files #{missing_because_deleted.join(", ")} were deleted, enqueuing job to regenerate them")
    StampPdfForPurchaseJob.perform_async(purchase_id)
  end

  def update_transcoded_videos_last_accessed_at
    videos_ids = alive_product_files.select { _1.filegroup == "video" }.map(&:id)
    return if videos_ids.empty?

    now = Time.current
    videos_ids.each_slice(1_000) do |slice|
      TranscodedVideo.alive
        .product_files
        .where(streamable_id: slice)
        .update_all(last_accessed_at: now)
    end
  end

  def enqueue_job_to_regenerate_deleted_transcoded_videos
    videos_ids = alive_product_files.select { _1.filegroup == "video" }.map(&:id)
    return if videos_ids.empty?

    alive = videos_ids.each_slice(1_000).flat_map do |slice|
      TranscodedVideo.alive
        .product_files
        .where(streamable_id: slice)
        .pluck(:streamable_id)
    end
    missing = (videos_ids - alive).uniq

    missing_because_deleted = ProductFile.where(id: missing)
      .joins(:transcoded_videos)
      .merge(TranscodedVideo.deleted.completed)
      .distinct
      .select(&:transcodable?)

    missing_because_deleted.each_with_index do |product_file, i|
      delay = 5.minutes * i
      TranscodeVideoForStreamingWorker.perform_in(delay, product_file.id, product_file.class.name)
    end
  end

  private
    def set_token
      self.token ||= self.class.generate_new_token
    end

    def rich_content_provider
      return @_rich_content_provider if instance_variable_defined?(:@_rich_content_provider)

      @_rich_content_provider = nil
      entity = with_product_files

      return if entity.blank? || entity.is_a?(Installment)

      @_rich_content_provider =
        if should_refer_to_product_level_rich_content_of_purchased_variant?(entity)
          entity.link
        elsif entity.is_a?(Link) || (entity.is_a?(BaseVariant) && entity.deleted?)
          product_or_cheapest_variant_as_rich_content_provider(entity)
        else
          entity
        end

      @_rich_content_provider
    end

    def has_purchased_variants_from_categories_with_files?
      return false unless purchase
      purchase.variant_attributes.any? do |variant|
        variant.is_a?(Variant) && (variant.has_files? || (variant.variant_category && variant.variant_category.variants.alive.any?(&:has_files?)))
      end
    end

    def has_purchased_variants_from_categories_with_rich_content?
      return false unless purchase
      purchase.variant_attributes.any? { _1.is_a?(Variant) }
    end

    def should_refer_to_product_level_rich_content_of_purchased_variant?(entity)
      return false unless entity.is_a?(BaseVariant)

      entity.link&.has_same_rich_content_for_all_variants? || false
    end

    def product_or_cheapest_variant_as_rich_content_provider(entity)
      product = entity.is_a?(BaseVariant) ? entity.link : entity
      return product if product.is_physical? || product.has_same_rich_content_for_all_variants? || product.rich_content_json.present? || product.alive_variants.none?

      product.alive_variants.order(price_difference_cents: :asc).first
    end
end
