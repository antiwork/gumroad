# frozen_string_literal: true

module WithProductFiles
  def self.included(base)
    base.class_eval do
      has_many :product_files
      has_many :ordered_alive_product_files, -> { alive.in_order }, class_name: "ProductFile"
      has_many :product_files_archives
      has_many :product_folders, -> { alive }, foreign_key: :product_id
      attr_accessor :cached_alive_product_files, :cached_rich_content_files_and_folders
    end
  end

  # Public: Returns a potentially cached list of alive files associated with the product.
  #
  # Retrieving the list of files from the same Link object happens often within certain controller actions.
  # Use this method in order to hit the db once and cache the results on the Link object and reuse them later.
  # Call this method only if you're sure that you're not changing the files within the same action.
  def alive_product_files
    cached_alive_product_files || self.cached_alive_product_files = product_files.alive.in_order.to_a
  end

  def has_files?
    product_files.alive.exists?
  end

  def save_files!(files_params, rich_content_params = [])
    files_to_keep = []
    new_product_files = []
    existing_files = alive_product_files
    existing_files_by_external_id = existing_files.index_by(&:external_id)
    should_check_pdf_stampability = false

    files_params.each do |file_params|
      next unless file_params[:url].present?

      begin
        external_id = file_params.delete(:external_id) || file_params.delete(:id)
        product_file = existing_files_by_external_id[external_id] || product_files.build(url: file_params[:url])
        files_to_keep << product_file

        # Defaults to true so that usage sites of this function continue
        # to work even if they do not take advantage of this optimization
        modified = ActiveModel::Type::Boolean.new.cast(file_params.delete(:modified) || true)

        next unless modified

        if product_file.new_record?
          new_product_files << product_file
          file_params[:is_linked_to_existing_file] = true if link && link.user.alive_product_files_excluding_product.where("product_files.url = ? AND product_files.link_id != ?", file_params[:url], link.id).any?
          WithProductFiles.associate_dropbox_file_and_product_file(product_file)
        end
        file_params.delete(:folder_id) if file_params[:folder_id].nil? && !(product_file.folder&.alive?)
        # TODO(product_edit_react) remove fallback
        subtitle_files_params = file_params.delete(:subtitle_files) || file_params.delete(:subtitles)&.values
        thumbnail_signed_id = file_params.delete(:thumbnail)&.dig(:signed_id) || file_params.delete(:thumbnail_signed_id)
        product_file.update!(file_params)

        should_check_pdf_stampability = true if product_file.saved_change_to_pdf_stamp_enabled? && product_file.pdf_stamp_enabled?

        # Update file embed IDs in rich content params before persisting changes
        if external_id != product_file.external_id
          rich_content_params.each { update_rich_content_file_id(_1, external_id, product_file.external_id) }
        end
        save_subtitle_files(product_file, subtitle_files_params)
        product_file.thumbnail.attach thumbnail_signed_id if thumbnail_signed_id.present?
      rescue ActiveRecord::RecordInvalid => e
        link&.errors&.add(:base, "#{file_params[:url]} is not a valid URL.") if e.message.include?("#{file_params[:url]} is not a valid URL.")
        link&.errors&.add(:base, "Please upload a thumbnail in JPG, PNG, or GIF format.") if e.message.include?("Please upload a thumbnail in JPG, PNG, or GIF format.")
        link&.errors&.add(:base, "Could not process your thumbnail, please upload an image with size smaller than 5 MB.") if e.message.include?("Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
        raise e
      end
    end

    (existing_files - files_to_keep).each(&:mark_deleted)
    self.cached_alive_product_files = nil
    generate_entity_archive! if is_a?(Installment) && needs_updated_entity_archive?

    link.content_updated_at = Time.current if new_product_files.any?(&:link_id?)
    PdfUnstampableNotifierJob.perform_in(5.seconds, link.id) if is_a?(Link) && should_check_pdf_stampability
    link&.enqueue_index_update_for(["filetypes"])
  end

  def transcode_videos!(queue: TranscodeVideoForStreamingWorker.sidekiq_options["queue"], first_batch_size: 30, additional_delay_after_first_batch: 5.minutes)
    # If we attempt to transcode too many videos at once, most would end up being processed on AWS Elemental Mediaconvert,
    # which is expensive, while our main Gumroad Mediaconvert is essentially free to use.
    # Spreading out transcodings for the same product allows other videos from other creators to still be processed
    # in a reasonable amount of time while preventing a high and unlimited AWS cost to be generated.
    # For context, the vast majority of products that have videos to transcode have less than 10 of them.

    alive_product_files.select(&:queue_for_transcoding?).each_with_index do |product_file, i|
      delay = i >= first_batch_size ? additional_delay_after_first_batch * i : 0
      TranscodeVideoForStreamingWorker.set(queue:).perform_in(delay, product_file.id, product_file.class.name)
    end
  end

  def has_been_transcoded?
    alive_product_files.each do |product_file|
      next unless product_file.streamable?
      return false unless product_file.transcoded_videos.alive.completed.exists?
    end
    true
  end

  def has_stream_only_files?
    alive_product_files.any?(&:stream_only?)
  end

  def stream_only?
    alive_product_files.all?(&:stream_only?)
  end

  def map_rich_content_files_and_folders
    return cached_rich_content_files_and_folders if cached_rich_content_files_and_folders

    return {} if alive_product_files.empty? || is_a?(Installment)

    pages = rich_contents&.alive
    has_only_one_page = pages.size == 1
    untitled_page_count = 0

    self.cached_rich_content_files_and_folders = pages.each_with_object({}) do |page, mapping|
      page.title = page.title.presence || (has_only_one_page ? nil : "Untitled #{untitled_page_count += 1}")
      untitled_folder_count = 0

      page.description.each do |node|
        if node["type"] == RichContent::FILE_EMBED_NODE_TYPE
          file = alive_product_files.find { |file| file.external_id == node.dig("attrs", "id") }
          mapping[file.id] = rich_content_mapping(page:, folder: nil, file:) if file.present?
        elsif node["type"] == RichContent::FILE_EMBED_GROUP_NODE_TYPE
          node["attrs"]["name"] = node.dig("attrs", "name").presence || "Untitled #{untitled_folder_count += 1}"
          node["content"].each do |file_node|
            file = alive_product_files.find { |file| file.external_id == file_node.dig("attrs", "id") }
            mapping[file.id] = rich_content_mapping(page:, folder: node["attrs"], file:) if file.present?
          end
        end
      end
    end
  end

  def folder_to_files_mapping
    map_rich_content_files_and_folders.each_with_object({}) do |(file_id, info), mapping|
      folder_id = info[:folder_id]
      next unless folder_id

      (mapping[folder_id] ||= []) << file_id
    end
  end

  def generate_folder_archives!(for_files: [])
    archives = product_files_archives.folder_archives.alive
    archived_folders = archives.pluck(:folder_id)
    folder_to_files = folder_to_files_mapping

    rich_content_folders = folder_to_files.keys
    existing_folders = archived_folders & rich_content_folders
    deleted_folders = archived_folders - rich_content_folders
    new_folders = rich_content_folders - archived_folders
    folders_need_updating = existing_folders.select do |folder_id|
      for_files.any? { folder_to_files[folder_id]&.include?(_1.id) } || archives.find_by(folder_id:)&.needs_updating?(product_files.alive)
    end

    archives.where(folder_id: (folders_need_updating + deleted_folders)).find_each(&:mark_deleted!)

    (folders_need_updating + new_folders).each do |folder_id|
      files_to_archive = alive_product_files.select { |file| folder_to_files[folder_id]&.include?(file.id) && file.archivable? }
      next if files_to_archive.count <= 1

      create_archive!(files_to_archive, folder_id)
    end
  end

  def generate_entity_archive!
    product_files_archives.entity_archives.alive.each(&:mark_deleted!)
    files_to_archive = alive_product_files.select(&:archivable?)
    return if files_to_archive.empty?

    create_archive!(files_to_archive, nil)
  end

  def has_stampable_pdfs?
    false
  end

  # Internal: Check if a zip archive should ever be generated for this product
  # This is for a product in general, not a specific purchase of a product.
  #
  # Examples:
  #
  # If there are stamped PDFs, this can never be included in a download all, so
  # don't generate a zip archive. Return false.
  #
  # If a product is rent_only, no files can be downloaded, so don't bother generating
  # a zip file. Return false.
  #
  # If a product is rentable and buyable, there is the possibility for some buyers to
  # download product_files. A zip archive should be prepared. Return true.
  def is_downloadable?
    return false if has_stampable_pdfs?
    return false if stream_only?

    true
  end

  def needs_updated_entity_archive?
    return false unless is_downloadable?

    archive = product_files_archives.latest_ready_entity_archive

    archive.nil? || archive.needs_updating?(product_files.alive)
  end

  private
    def create_archive!(files_to_archive, folder_id = nil)
      product_files_archive = product_files_archives.new(folder_id:)
      product_files_archive.product_files = files_to_archive
      product_files_archive.save!
      product_files_archive.set_url_if_not_present
      product_files_archive.save!
    end

    def rich_content_mapping(page:, folder: nil, file:)
      { page_id: page.external_id,
        page_title: page.title.presence,
        folder_id: folder&.fetch("uid", nil),
        folder_name: folder&.fetch("name", nil),
        file_id: file.external_id,
        file_name: file.name_displayable }
    end

    def save_subtitle_files(product_file, subtitle_files_params)
      product_file.save_subtitle_files!(subtitle_files_params || {})
    rescue ActiveRecord::RecordInvalid => e
      errors.add(:base, e.message)
      raise e
    end

    # Private: associate_dropbox_file_and_product_file
    #
    # product_file - The product file we are looking to associate to a dropbox file
    #
    # This method associates a newly created product file and an existing dropbox file if it exists.
    # We must do this to prevent a user from seeing a previouly associated dropbox file when they visit
    # the product edit page or product creation page. Once a dropbox file is associated to a product file
    # the dropbox file should never be displayed to the user in the ui.
    #
    def self.associate_dropbox_file_and_product_file(product_file)
      return if product_file.link.try(:user).nil?

      user_dropbox_files = product_file.link.user.dropbox_files
      dropbox_file = user_dropbox_files.where(s3_url: product_file.url, product_file_id: nil).first
      return if dropbox_file.nil?

      dropbox_file.product_file = product_file
      dropbox_file.link = product_file.link
      dropbox_file.save!
    end

    def update_rich_content_file_id(rich_content, from, to)
      if rich_content["type"] == "fileEmbed" && rich_content["attrs"]["id"] == from
        rich_content["attrs"]["id"] = to
      end
      rich_content["content"].each { update_rich_content_file_id(_1, from, to) } if rich_content["content"].present?
    end
end
