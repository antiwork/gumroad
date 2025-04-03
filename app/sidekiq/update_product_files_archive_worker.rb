# frozen_string_literal: true

class UpdateProductFilesArchiveWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  PRODUCT_FILES_ARCHIVE_FILE_SIZE_LIMIT = 500.megabytes
  UNTITLED_FILENAME = "Untitled"

  # On an EXT4 file system, the command "getconf PATH_MAX /" returns 255 which
  # is an indication that the pathname cannot exceed 255 bytes.
  # The actual Tempfile pathname can be much longer than the actual name of
  # the file.
  #
  # For example:
  # > "个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子".bytesize
  # => 240
  # > "/tmp/个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子人个出租车学习杯子.csv20210323-608-1hgzlxi".bytesize
  # => 269
  #
  # Therefore, to avoid running into "Errno::ENAMETOOLONG (File name too long)"
  # error, we can safely set the bytesize limit for the actual name of the file
  # much smaller.
  MAX_FILENAME_BYTESIZE = 150

  def initialize
    @used_file_paths = []
  end

  def perform(product_files_archive_id)
    return if Rails.env.test?

    product_files_archive = ProductFilesArchive.find(product_files_archive_id)
    # Check for nil immediately, product_files_archive has mysteriously been
    # nil which locks up workers by not failing properly
    if product_files_archive.nil?
      Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - Archive var was not set")
      return
    end

    if product_files_archive.deleted?
      Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - Archive is deleted")
      return
    end

    Rails.logger.info("Beginning UpdateProductFilesArchive Job for #{product_files_archive.id}")
    product_files_archive.mark_in_progress!

    # Check the estimated size of the archive. If it is larger than our limit,
    # mark the product_files_archive as failed and exit the job.
    estimated_size = calculate_estimated_size(product_files_archive)
    if estimated_size > PRODUCT_FILES_ARCHIVE_FILE_SIZE_LIMIT
      product_files_archive.mark_failed!
      Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - Archive is too large.")
      return
    end

    zip_archive_filename = File.join(Dir.tmpdir, "#{product_files_archive.external_id}.zip")
    product_files = product_files_archive.product_files.not_external_link
    rich_content_files_and_folders_mapping = product_files_archive.rich_content_provider&.map_rich_content_files_and_folders
    Zip::File.open(zip_archive_filename, Zip::File::CREATE) do |zip_file|
      product_files.each do |product_file|
        next if product_file.stream_only?

        if rich_content_files_and_folders_mapping.nil?
          file_path_parts = [product_file.folder&.name, product_file.name_displayable]
        else
          file_info = rich_content_files_and_folders_mapping[product_file.id]
          next if file_info.nil?
          directory_info = product_files_archive.folder_archive? ? [] : [file_info[:page_title], file_info[:folder_name]]
          file_path_parts = directory_info.concat([file_info[:file_name]])
        end
        file_path = compose_file_path(file_path_parts, product_file.s3_extension)
        zip_file.get_output_stream(file_path) do |output_stream|
          temp_file = Tempfile.new
          begin
            product_file.s3_object.download_file(temp_file.path)
          rescue Aws::S3::Errors::NotFound
            # If the file does not exist on S3 for any reason, abandon this job without raising an error.
            product_files_archive.mark_failed!
            Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - missing file #{product_file.id}")
            return
          end
          temp_file.rewind
          output_stream.write(temp_file.read)
        end
      end
    end

    unless File.exist?(zip_archive_filename)
      product_files_archive.mark_failed!
      Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - Zip file was not written.")
      return
    end

    # NOTE: Probably better to not have to reopen this file, but couldn't get a
    # variable to hold the zip file, so had to do it this way.
    file = File.open(zip_archive_filename, "rb")
    archive_s3_object = product_files_archive.s3_object
    archive_s3_object.upload_file(file, content_type: "application/zip")
    product_files_archive.mark_ready!
    Rails.logger.info("UpdateProductFilesArchive job completed for id #{product_files_archive.id}.")
  rescue NoMemoryError, Aws::S3::Errors::NoSuchKey, Errno::ENOENT, Seahorse::Client::NetworkingError, Aws::S3::Errors::ServiceError => e
    file&.close
    delete_temp_zip_file_if_exists(zip_archive_filename)

    product_files_archive.mark_failed!
    Bugsnag.notify(e)
    Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - #{e.class.name}: #{e.message}")
    raise e
  ensure
    file&.close
    delete_temp_zip_file_if_exists(zip_archive_filename)
  end

  # Helper method to delete any zip files that might get left around
  def delete_temp_zip_file_if_exists(zip_archive_filename)
    if zip_archive_filename && File.exist?(zip_archive_filename)
      if File.delete(zip_archive_filename)
        Rails.logger.info("Temporary zip file deleted.")
      else
        Rails.logger.info("Zip file was not deleted.")
      end
    end
  end

  def calculate_estimated_size(product_files_archive)
    Rails.logger.info("Calculating estimated archive size.")
    estimated_size = 0
    product_files_archive.product_files.each do |product_file|
      if product_file.size
        estimated_size += product_file.size
      else
        Rails.logger.info("Fetching product file size from S3.")
        estimated_size += product_file.s3_object.content_length if product_file.s3?
      end
    end
    estimated_size
  end

  private
    attr_reader :used_file_paths

    def compose_file_path(file_path_parts, extension)
      file_path_parts = file_path_parts.map { |name| sanitize_filename(name || "") }.compact_blank

      # Some file systems have a strict limit on the file path length of
      # approx 255 bytes (Reference: https://serverfault.com/a/9548/122209).
      # Since the file name can be a multibyte unicode string, we must
      # truncate the string by multibyte characters (graphemes).
      path_without_extension = truncate_path(file_path_parts)
      file_path = "#{path_without_extension}#{extension}"

      # Make sure each entry in the zip file has a unique path. If entry names are not unique the zip file will be corrupted.
      suffix = 1
      while used_file_paths.include?(file_path.downcase)
        file_path = "#{path_without_extension}-#{suffix}#{extension}"
        suffix += 1
      end
      used_file_paths << file_path.downcase # Some FSs will compare file/folder names in a case-insensitive way

      file_path
    end

    def sanitize_filename(filename)
      filename = ActiveStorage::Filename.new(filename).sanitized

      # Additional rules for Windows https://docs.microsoft.com/en-us/windows/win32/fileio/naming-a-file#naming-conventions
      filename = filename.gsub(/[<>:"\/\\|?*]/, "-").gsub(/[ .]*\z/, "")

      filename
    end

    def truncate_path(path_parts)
      truncate_part_by_percent = 0.75
      while File.join(path_parts).bytesize > MAX_FILENAME_BYTESIZE
        longest_part = path_parts.max_by(&:bytesize)
        if longest_part == path_parts.last && path_parts.length > 1 && longest_part.bytesize <= UNTITLED_FILENAME.bytesize
          path_parts.shift
        else
          truncate_to_bytesize = path_parts.length == 1 ? MAX_FILENAME_BYTESIZE : longest_part.bytesize * truncate_part_by_percent
          path_parts[path_parts.index(longest_part)] = longest_part.truncate_bytes((truncate_to_bytesize).round, omission: nil)
        end

        path_parts.compact_blank!
      end

      File.join(path_parts)
    end
end
