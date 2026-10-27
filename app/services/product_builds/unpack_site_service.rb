# frozen_string_literal: true

# Unpacks a promoted build into builds/<product_id>/<number>/site/, the prefix the player serves.
# The zip is seller-supplied, so every entry is treated as hostile: the path is confined to the
# site prefix (no absolute paths, no `..`, no backslashes, no symlinks) and the unpack stops as
# soon as the file count or the total uncompressed size passes its limit, so a zip bomb cannot
# fill the bucket or the disk. The size an entry declares in the archive is never trusted.
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
      s3 = Aws::S3::Client.new
      file_count = 0
      byte_size = 0
      has_index = false

      Zip::File.open(zip_path) do |zip|
        zip.each do |entry|
          next if entry.directory?
          raise UnpackError, "A build cannot contain symlinks: #{shown(entry.name)}." if entry.symlink?
          raise UnpackError, "A build can have at most #{ProductBuild::MAX_SITE_FILES} files." if file_count >= ProductBuild::MAX_SITE_FILES

          path = site_path(entry.name)
          written = copy_entry(entry, path, s3, ProductBuild::MAX_SITE_BYTE_SIZE - byte_size)
          file_count += 1
          byte_size += written
          has_index = true if path == "index.html"
        end
      end

      raise UnpackError, "The zip has no index.html at its root, so there is nothing to play." unless has_index

      build.update!(site_unpacked_at: Time.current, site_file_count: file_count, site_byte_size: byte_size, site_unpack_error: nil)
    end

    # Copies one entry into the build's site prefix, stopping as soon as it passes the bytes left in
    # the budget: the length the archive declares for the entry is not trusted.
    def copy_entry(entry, path, s3, remaining_bytes)
      Tempfile.create(["entry", File.extname(path)]) do |file|
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

    # The entry's path relative to the site prefix, or an error when the entry tries to leave it.
    def site_path(name)
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
