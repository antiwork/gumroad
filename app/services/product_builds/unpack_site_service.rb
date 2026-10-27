# frozen_string_literal: true

# Unpacks a promoted build into builds/<product_id>/<number>/site/, the prefix the player serves.
# The zip is seller-supplied, so every entry is treated as hostile: the path is confined to the
# site prefix (no absolute paths, no `..`, no backslashes, no symlinks) and the unpack stops as
# soon as the file count or the total uncompressed size passes its limit, so a zip bomb cannot
# fill the bucket or the disk. The size an entry declares in the archive is never trusted.
#
# A zip whose files all sit inside one top-level folder (`zip -r game.zip game/`, what a seller's
# OS produces by default) is unpacked from the inside of that folder, so `game/index.html` plays
# the same as a zip whose index.html is at its root. Every other layout is a bad build: no
# index.html once that folder is stripped, or more than one top-level entry.
#
# The entry count and the metadata bytes an archive's central directory actually holds are measured
# before the archive is opened, because rubyzip reads every record in it into memory on open.
class ProductBuilds::UnpackSiteService
  class UnpackError < StandardError; end

  # What the browser needs to run a build's files without sniffing them.
  CONTENT_TYPES = {
    "html" => "text/html",
    "htm" => "text/html",
    "js" => "text/javascript",
    "mjs" => "text/javascript",
    "cjs" => "text/javascript",
    "css" => "text/css",
    "json" => "application/json",
    "wasm" => "application/wasm",
    "txt" => "text/plain",
    "xml" => "application/xml",
    "svg" => "image/svg+xml",
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp",
    "avif" => "image/avif",
    "ico" => "image/vnd.microsoft.icon",
    "mp3" => "audio/mpeg",
    "ogg" => "audio/ogg",
    "oga" => "audio/ogg",
    "wav" => "audio/wav",
    "m4a" => "audio/mp4",
    "mp4" => "video/mp4",
    "webm" => "video/webm",
    "woff" => "font/woff",
    "woff2" => "font/woff2",
    "ttf" => "font/ttf",
    "otf" => "font/otf",
  }.freeze
  DEFAULT_CONTENT_TYPE = "application/octet-stream"
  ENTRY_NAME_MAX_LENGTH = 100

  # rubyzip holds every central-directory record in memory the moment the archive is opened, so the
  # directory is walked here first, with the budgets a build may hold. Counting entries alone would
  # not bound that: one record can carry a 64 KB name, so the bytes the records occupy are budgeted
  # too. The directory's own declared count is not read at all — the records carry their own
  # lengths, so only walking them says what the archive really holds.
  CENTRAL_DIRECTORY_ENTRY_SIGNATURE = "PK\x01\x02".b
  CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE = 46
  EOCD_SIGNATURE = "PK\x05\x06".b
  ZIP64_EOCD_SIGNATURE = "PK\x06\x06".b
  ZIP64_EOCD_LOCATOR_SIGNATURE = "PK\x06\x07".b
  # The end-of-central-directory record plus the longest comment a zip can carry behind it.
  EOCD_SEARCH_WINDOW = 70_000
  # Room for the folder entries an archive carries on top of the files they hold.
  ARCHIVE_ENTRY_SLACK = 1_024
  # 5000 files at ~100 bytes of directory record each is about half a megabyte, so this leaves an
  # order of magnitude of headroom for the extras real zips carry while still bounding the memory a
  # hostile archive can make the worker hold.
  ARCHIVE_METADATA_BYTE_BUDGET = 8.megabytes

  def self.perform(build) = new(build).perform

  def initialize(build)
    @build = build
  end

  def perform
    return build if build.site_ready?

    Tempfile.create(["build", ".zip"]) do |zip_file|
      zip_file.binmode
      download(zip_file)
      unpack(zip_file.path)
    end
    build
  rescue UnpackError => e
    # A rejected zip must leave nothing behind: a half-written site/ would be served once the
    # player exists, and the seller has to upload a fixed zip as a new build anyway.
    delete_written_files
    build.update!(site_unpack_error: e.message)
    raise
  end

  private
    attr_reader :build

    def written_keys
      @written_keys ||= []
    end

    def delete_written_files
      return if written_keys.empty?

      s3 = Aws::S3::Client.new
      written_keys.each { |key| s3.delete_object(bucket: S3_BUCKET, key:) }
      written_keys.clear
    end

    def download(zip_file)
      Aws::S3::Client.new.get_object(bucket: S3_BUCKET, key: build.storage_key, response_target: zip_file.path)
    end

    def unpack(zip_path)
      check_directory(zip_path)

      s3 = Aws::S3::Client.new
      file_count = 0
      byte_size = 0
      has_index = false

      Zip::File.open(zip_path) do |zip|
        files = zip.reject(&:directory?)
        # Whether the zip wraps the site in a folder is a property of the whole archive, so it is
        # decided from the names before anything is copied: a layout we reject must not leave a
        # half-written site behind.
        folder = folder_to_strip(files.map { normalize_entry_name(_1.name) })

        files.each do |entry|
          raise UnpackError, "A build cannot contain symlinks: #{shown(entry.name)}." if entry.symlink?
          raise UnpackError, "A build can have at most #{ProductBuild::MAX_SITE_FILES} files." if file_count >= ProductBuild::MAX_SITE_FILES

          path = relative_entry_name(entry.name, folder)
          written = copy_entry(entry, path, s3, ProductBuild::MAX_SITE_BYTE_SIZE - byte_size)
          file_count += 1
          byte_size += written
          has_index = true if path == "index.html"
        end
      end

      raise UnpackError, "The zip has no index.html at its root, so there is nothing to play." unless has_index

      build.update!(site_unpacked_at: Time.current, site_file_count: file_count, site_byte_size: byte_size, site_unpack_error: nil)
    rescue Zip::Error
      # An archive rubyzip cannot read is a seller input error like the ones above, not a transient
      # one: reject it the same way instead of letting the job retry a zip that will never open.
      raise UnpackError, "The zip could not be read, so there is nothing to play."
    end

    # The entries a build may hold: its files, plus the folder entries an archive carries for them.
    def max_archive_entries = ProductBuild::MAX_SITE_FILES * 2 + ARCHIVE_ENTRY_SLACK

    # Walks the archive's central directory without opening it, which is the memory rubyzip is about
    # to spend: the records it holds there are counted and measured, and the walk stops as soon as
    # either budget is passed. A record's name and comment lengths are read from the record itself,
    # which is why the bytes are budgeted next to the count: a handful of entries can carry megabytes
    # of names.
    def check_directory(zip_path)
      File.open(zip_path, "rb") do |file|
        offset = central_directory_offset(file)
        return if offset.nil? || offset > file.size

        file.seek(offset)
        entries = 0
        metadata_bytes = 0

        loop do
          header = file.read(CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE)
          break if header.nil? || header.bytesize < CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE
          break unless header.start_with?(CENTRAL_DIRECTORY_ENTRY_SIGNATURE)

          name_length, extra_length, comment_length = header[28, 6].unpack("vvv")
          record_size = CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE + name_length + extra_length + comment_length
          entries += 1
          metadata_bytes += record_size
          raise UnpackError, "The zip has more entries than a build may hold." if entries > max_archive_entries
          raise UnpackError, "The zip's entry names and folders take up more room than a build may hold." if metadata_bytes > ARCHIVE_METADATA_BYTE_BUDGET

          file.seek(record_size - CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE, IO::SEEK_CUR)
        end
      end
    end

    # Where the archive's directory starts, read from the same record rubyzip will read it from: it
    # takes the ZIP64 record whenever both of its signatures are in the archive's tail, whatever the
    # record before it says. When neither is there, rubyzip cannot open the archive either, and the
    # walk has nothing to measure.
    def central_directory_offset(file)
      file.seek([file.size - EOCD_SEARCH_WINDOW, 0].max)
      tail = file.read

      if tail.include?(ZIP64_EOCD_LOCATOR_SIGNATURE) && (zip64 = tail.rindex(ZIP64_EOCD_SIGNATURE))
        return tail[zip64 + 48, 8]&.unpack1("Q<")
      end

      eocd = tail.rindex(EOCD_SIGNATURE)
      return nil unless eocd

      tail[eocd + 16, 4]&.unpack1("V")
    end

    # Copies one entry into the build's site prefix, stopping as soon as it passes the bytes left in
    # the budget: the length the archive declares for the entry is not trusted.
    def copy_entry(entry, path, s3, remaining_bytes)
      Tempfile.create("entry") do |file|
        file.binmode
        copied = IO.copy_stream(entry.get_input_stream, file, remaining_bytes + 1)
        if copied > remaining_bytes
          raise UnpackError, "A build's files can unpack to at most #{ProductBuild::MAX_SITE_BYTE_SIZE / 1.gigabyte} GB."
        end

        file.rewind
        key = "#{build.site_prefix}/#{path}"
        s3.put_object(
          bucket: S3_BUCKET,
          key:,
          body: file,
          content_length: copied,
          content_type: content_type_for(path),
        )
        written_keys << key
        copied
      end
    end

    # The single folder the zip wraps the whole site in, or nil when the site sits at its root.
    # `zip -r game.zip game/` is what a seller's own machine produces, so that one shape is
    # unpacked from the inside; a zip with more than one top-level entry has no single site to
    # play, and one whose single top-level name is a file is left to the index.html check.
    def folder_to_strip(paths)
      return nil if paths.include?("index.html")

      top_level = paths.map { |path| path.split("/").first }.uniq
      raise UnpackError, "The zip has more than one top-level entry, so there is no single site to play." if top_level.size > 1

      top_level.first if paths.all? { |path| path.start_with?("#{top_level.first}/") }
    end

    # The entry's path relative to the site prefix, once the folder the zip wraps it in is gone.
    def relative_entry_name(name, folder)
      path = normalize_entry_name(name)
      folder ? path.delete_prefix("#{folder}/") : path
    end

    # The entry's path relative to the site prefix, or an error when the entry tries to leave it.
    def normalize_entry_name(name)
      name = name.to_s
      raise UnpackError, "The zip has an entry with no name." if name.empty?
      raise UnpackError, "The zip has an entry with an unsafe name: #{shown(name)}." if name.include?("\0") || name.include?("\\")
      raise UnpackError, "The zip has an absolute path: #{shown(name)}." if name.start_with?("/") || name.match?(/\A[A-Za-z]:/)

      segments = name.split("/").reject { _1.empty? || _1 == "." }
      if segments.empty? || segments.any? { _1 == ".." }
        raise UnpackError, "The zip has an entry outside its own folder: #{shown(name)}."
      end

      segments.join("/")
    end

    def content_type_for(path)
      CONTENT_TYPES[File.extname(path).delete_prefix(".").downcase] || DEFAULT_CONTENT_TYPE
    end

    def shown(name)
      name.to_s.truncate(ENTRY_NAME_MAX_LENGTH)
    end
end
