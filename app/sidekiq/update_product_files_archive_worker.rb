# frozen_string_literal: true

class UpdateProductFilesArchiveWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # A run that lost its lock re-raises without touching the row, so the last retry can leave it
  # in_progress, which UrlRedirect reads as a build still running. Mark it failed unless a run holds the lock.
  sidekiq_retries_exhausted do |message, _error|
    product_files_archive_id = message.fetch("args").first
    next if $redis.exists?(lock_key(product_files_archive_id))

    product_files_archive = ProductFilesArchive.find_by(id: product_files_archive_id)
    product_files_archive&.with_lock { product_files_archive.mark_failed! if product_files_archive.in_progress? }
  end

  PRODUCT_FILES_ARCHIVE_FILE_SIZE_LIMIT = 500.megabytes
  # Only bundle ZIPs go past the old limit. Product and folder ZIPs are rebuilt on every content
  # change, and the download page hides their buttons above 500 MB (RichContent.tsx).
  BUNDLE_ARCHIVE_FILE_SIZE_LIMIT = 8.gigabytes
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

  # Bounds the HEAD requests and the central directory a bundle build keeps in memory. Other
  # archives are held to PRODUCT_FILES_ARCHIVE_FILE_SIZE_LIMIT, and too_large is final for them.
  MAX_ARCHIVE_ENTRIES = 10_000
  # Each upload thread buffers one part, so upload memory is about UPLOAD_CONCURRENCY * UPLOAD_PART_SIZE.
  UPLOAD_PART_SIZE = 16.megabytes
  UPLOAD_CONCURRENCY = 4
  SOURCE_READ_ATTEMPTS = 3

  class SourceChangedError < StandardError; end
  class ArchiveSizeMismatchError < StandardError; end
  # Raised so Sidekiq retries: the key vanished (expiry, eviction, failover) and no run owns the row.
  class LockLostError < StandardError; end
  class LockTakenError < StandardError; end
  # The upload closed its pipe after a part failed; the SDK reports that part's error.
  class UploadClosedError < StandardError; end

  # Renewed before each file and every LOCK_RENEWAL_INTERVAL while one streams; a crashed run
  # delays the next rebuild by at most the TTL.
  LOCK_TTL = 30.minutes
  LOCK_RENEWAL_INTERVAL = 1.minute
  LOCKED_RETRY_DELAY = 1.minute
  RELEASE_LOCK_SCRIPT = <<~LUA
    if redis.call("get", KEYS[1]) == ARGV[1] then return redis.call("del", KEYS[1]) end
    return 0
  LUA
  RENEW_LOCK_SCRIPT = <<~LUA
    if redis.call("get", KEYS[1]) == ARGV[1] then return redis.call("expire", KEYS[1], ARGV[2]) end
    return 0
  LUA
  private_constant :RELEASE_LOCK_SCRIPT, :RENEW_LOCK_SCRIPT

  def self.lock_key(product_files_archive_id)
    "update_product_files_archive_worker:lock:#{product_files_archive_id}"
  end

  def perform(product_files_archive_id)
    return if Rails.env.test?

    # Concurrent runs for one archive race on its state and S3 object, so a second run defers
    # instead of being dropped: it may carry bytes the running build has not seen.
    @lock_key = self.class.lock_key(product_files_archive_id)
    @lock_token = SecureRandom.uuid
    unless $redis.set(@lock_key, @lock_token, nx: true, ex: LOCK_TTL.to_i)
      self.class.perform_in(LOCKED_RETRY_DELAY, product_files_archive_id)
      return
    end

    begin
      build_archive(product_files_archive_id)
    ensure
      $redis.eval(RELEASE_LOCK_SCRIPT, keys: [@lock_key], argv: [@lock_token])
    end
  end

  def build_archive(product_files_archive_id)
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

    # Recorded sizes rule out an oversize archive before any request; the HEAD sizes below decide.
    bundle = product_files_archive.bundle_purchase_archive?
    size_limit = bundle ? BUNDLE_ARCHIVE_FILE_SIZE_LIMIT : PRODUCT_FILES_ARCHIVE_FILE_SIZE_LIMIT
    entries = archive_entries(product_files_archive)
    recorded_size = entries.sum { |product_file, _| product_file.size.to_i }
    if (bundle && entries.size > MAX_ARCHIVE_ENTRIES) || recorded_size > size_limit
      mark_too_large(product_files_archive)
      return
    end
    if entries.empty?
      product_files_archive.mark_failed!
      Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - No files to archive.")
      return
    end

    sources = entries.map do |product_file, file_path|
      renew_lock!
      head = source_client.head_object(bucket: S3_BUCKET, key: product_file.s3_key)
      [product_file.s3_key, file_path, head.content_length, head.etag]
    rescue Aws::S3::Errors::NotFound
      # If the file does not exist on S3 for any reason, abandon this job without raising an error.
      product_files_archive.mark_failed!
      Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - missing file #{product_file.id}")
      return
    end

    if sources.sum { |_, _, size, _| size } > size_limit
      mark_too_large(product_files_archive)
      return
    end

    # The HEAD pass can outlast the lock. Confirm this run still owns it before aborting every
    # unfinished upload at the key, or a newer run's upload is destroyed.
    renew_lock!
    abort_unfinished_uploads(product_files_archive)
    archive_object = product_files_archive.s3_object
    zip = nil
    upload_archive(archive_object) do |pipe|
      # The SDK's pipe is in text mode, where Rails' UTF-8 default_internal transcodes each write.
      pipe.binmode
      zip = StreamingZipWriter.new(pipe)
      sources.each do |source_key, file_path, size, etag|
        renew_lock!
        # Only inputs just under 4 GiB can deflate past it, so only they are read twice.
        compressed_size = if StreamingZipWriter.compressed_size_needed?(size)
          zip.deflated_size { |counter| stream_source(source_key, size, etag, counter) }
        end
        zip.write_entry(file_path, size:, compressed_size:) { |entry_data| stream_source(source_key, size, etag, entry_data) }
      end
      zip.close
    end
    renew_lock!
    stored_size = archive_object.client.head_object(bucket: archive_object.bucket_name, key: archive_object.key).content_length
    raise ArchiveSizeMismatchError, "stored #{stored_size} bytes, wrote #{zip.bytes_written}" if stored_size != zip.bytes_written

    # A file rewritten mid-build resets the archive to queueing and enqueues a rebuild; this ZIP
    # may hold its old bytes, so leave it hidden for that rebuild.
    product_files_archive.with_lock do
      product_files_archive.mark_ready! if product_files_archive.in_progress?
    end
    Rails.logger.info("UpdateProductFilesArchive job completed for id #{product_files_archive.id} " \
                      "(#{entries.size} files, #{zip.bytes_written} bytes).")
  rescue LockTakenError
    Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} stopped - another run holds the lock")
  rescue NoMemoryError, Aws::S3::Errors::NoSuchKey, Seahorse::Client::NetworkingError, Aws::S3::Errors::ServiceError,
         Aws::S3::MultipartUploadError, SourceChangedError, StreamingZipWriter::SizeMismatchError, ArchiveSizeMismatchError => e
    ErrorNotifier.notify(e)
    Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - #{e.class.name}: #{e.message}")
    # Only the lock holder may change the row: with no holder, Sidekiq's retry rebuilds it.
    holder = $redis.get(@lock_key)
    if holder != @lock_token
      raise e if holder.nil?
      return
    end
    reset_for_rebuild = product_files_archive.with_lock do
      product_files_archive.mark_failed! if product_files_archive.in_progress?
      product_files_archive.queueing?
    end
    # The reset already enqueued the rebuild, so a retry here would only build the archive twice.
    raise e unless reset_for_rebuild
  end

  private
    attr_reader :used_file_paths

    def archive_entries(product_files_archive)
      @used_file_paths = []
      bundle_purchase_archive = product_files_archive.bundle_purchase_archive?
      rich_content_files_and_folders_mapping = product_files_archive.rich_content_provider&.map_rich_content_files_and_folders
      # Ordered so a retry or rebuild hands out the same collision suffixes.
      product_files_archive.product_files.not_external_link.order(:id).filter_map do |product_file|
        next if product_file.stream_only?

        if bundle_purchase_archive
          file_path_parts = [product_file.link.name, product_file.folder&.name, product_file.name_displayable]
        elsif rich_content_files_and_folders_mapping.nil?
          file_path_parts = [product_file.folder&.name, product_file.name_displayable]
        else
          file_info = rich_content_files_and_folders_mapping[product_file.id]
          next if file_info.nil?
          directory_info = product_files_archive.folder_archive? ? [] : [file_info[:page_title], file_info[:folder_name]]
          file_path_parts = directory_info.concat([file_info[:file_name]])
        end
        [product_file, compose_file_path(file_path_parts, product_file.s3_extension)]
      end
    end

    def mark_too_large(product_files_archive)
      product_files_archive.mark_too_large!
      Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} failed - Archive is too large.")
    end

    # Reads the object in one streamed GET, resuming at the last byte received after a dropped
    # connection. A completed read that adds no bytes counts as a failed attempt. If-Match pins
    # every request to the ETag the size came from, so a replaced source cannot mix two versions.
    def stream_source(key, size, etag, entry_data)
      received = 0
      failed_reads = 0
      while received < size
        before = received
        error = nil
        begin
          source_client.get_object(bucket: S3_BUCKET, key:, if_match: etag, range: "bytes=#{received}-#{size - 1}") do |chunk|
            received += chunk.bytesize
            raise SourceChangedError, "#{key} sent more than #{size} bytes" if received > size

            write_to_upload(entry_data, chunk)
            renew_lock! if lock_renewal_due?
          end
        rescue Seahorse::Client::NetworkingError => e
          error = e
        end
        # Progress resets the count, so it bounds consecutive failed reads, not all of them.
        if received > before
          failed_reads = 0
          next
        end

        failed_reads += 1
        raise(error || Seahorse::Client::NetworkingError.new(Errno::ECONNRESET.new)) if failed_reads >= SOURCE_READ_ATTEMPTS
      end
    end

    # Seahorse reports an error raised in the get_object block as a dropped read (IOError and EPIPE
    # are network errors to it), which stream_source would retry against a pipe that stays closed.
    def write_to_upload(entry_data, chunk)
      entry_data.write(chunk)
    rescue IOError, Errno::EPIPE => e
      raise UploadClosedError, e.message
    end

    # One client for every source; S3Retrievable#s3_object builds a new one per call.
    def source_client
      @source_client ||= Aws::S3::Client.new
    end

    def lock_renewal_due?
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - @lock_renewed_at >= LOCK_RENEWAL_INTERVAL
    end

    def renew_lock!
      renewed = $redis.eval(RENEW_LOCK_SCRIPT, keys: [@lock_key], argv: [@lock_token, LOCK_TTL.to_i])
      raise($redis.get(@lock_key).nil? ? LockLostError : LockTakenError) if renewed != 1

      @lock_renewed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # The SDK aborts the upload on any StandardError from the block or a part and raises
    # MultipartUploadError. Closing its pipe makes the other side fail too (IOError, EPIPE), so
    # re-raise the error that started it, which keeps its handling here. An Interrupt
    # (Sidekiq::Shutdown) skips that abort; the requeued run's abort_unfinished_uploads clears it.
    def upload_archive(archive_object, &block)
      archive_object.upload_stream(part_size: UPLOAD_PART_SIZE, thread_count: UPLOAD_CONCURRENCY,
                                   content_type: "application/zip", checksum_algorithm: "CRC32", &block)
    rescue Aws::S3::MultipartUploadError => e
      raise(e.errors.find { !_1.is_a?(IOError) && !_1.is_a?(Errno::EPIPE) && !_1.is_a?(UploadClosedError) } || e)
    end

    # A killed or interrupted build never aborts its upload, so its parts stay stored until the bucket
    # expires them. Best effort: a build that cannot list uploads (missing permission, S3 error) still runs.
    def abort_unfinished_uploads(product_files_archive)
      object = product_files_archive.s3_object
      uploads = object.client.list_multipart_uploads(bucket: object.bucket_name, prefix: object.key).uploads.select { _1.key == object.key }
      uploads.each { object.client.abort_multipart_upload(bucket: object.bucket_name, key: object.key, upload_id: _1.upload_id) }
      Rails.logger.info("UpdateProductFilesArchive Job #{product_files_archive.id} aborted #{uploads.size} unfinished uploads") if uploads.any?
    rescue Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError => e
      ErrorNotifier.notify(e)
    end

    def compose_file_path(file_path_parts, extension)
      file_path_parts = file_path_parts.map { |name| sanitize_filename(name || "") }.compact_blank

      # Some file systems have a strict limit on the file path length of
      # approx 255 bytes (Reference: https://serverfault.com/a/9548/122209).
      # Since the file name can be a multibyte unicode string, we must
      # truncate the string by multibyte characters (graphemes).
      path_without_extension = truncate_path(file_path_parts).presence || UNTITLED_FILENAME
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
