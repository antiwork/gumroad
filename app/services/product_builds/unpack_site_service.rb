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
  S3_KEY_MAX_BYTES = 1_024
  UNREADABLE_ARCHIVE = "The zip could not be read, so there is nothing to play."

  # rubyzip holds every central-directory record in memory the moment the archive is opened, so the
  # directory is walked here first, with the budgets a build may hold. Counting entries alone would
  # not bound that: one record can carry a 64 KB name, so the bytes the records occupy are budgeted
  # too. The walk reads exactly the directory rubyzip will read — the record it picks, the count it
  # declares, in the window it searches for that record — so what was measured and what gets loaded
  # cannot be two different things: an archive whose directory does not match its own description is
  # rejected instead of opened.
  CENTRAL_DIRECTORY_ENTRY_SIGNATURE = "PK\x01\x02".b
  CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE = 46
  EOCD_SIGNATURE = "PK\x05\x06".b
  ZIP64_EOCD_SIGNATURE = "PK\x06\x06".b
  ZIP64_EOCD_LOCATOR_SIGNATURE = "PK\x06\x07".b
  # rubyzip decides which of the two end-of-directory records an archive has by looking for their
  # signatures in this many bytes of the archive's tail, so the same window is read here: the walk
  # has to pick the same record, or it measures a directory rubyzip would not read.
  EOCD_SEARCH_WINDOW = 65_554
  # Room for the folder entries an archive carries on top of the files they hold.
  ARCHIVE_ENTRY_SLACK = 1_024
  # 5000 files at ~100 bytes of directory record each is about half a megabyte, so this leaves an
  # order of magnitude of headroom for the extras real zips carry while still bounding the memory a
  # hostile archive can make the worker hold.
  ARCHIVE_METADATA_BYTE_BUDGET = 8.megabytes
  # What rubyzip reads from the archive at a time. A chunk runs past the entry that asked for it, so
  # it is also what each entry costs the read budget below.
  ARCHIVE_READ_CHUNK = 32_768
  # An archive whose directory does not hold the records it says it does is not one rubyzip can read
  # back the way it describes itself, so it is rejected before it is opened.
  MALFORMED_DIRECTORY = "The zip's directory does not hold the entries it says it does, so it cannot be unpacked."

  # What the unpack has read out of the archive. One object per archive, shared by every copy of the
  # archive IO: rubyzip dups that IO for each entry it opens, so a counter held by the IO would only
  # ever see one entry's reads.
  class ReadBudget
    def initialize(limit)
      @limit = limit
      @read = 0
    end

    def add(bytes)
      @read += bytes
      return if @read <= @limit

      raise UnpackError, "The zip reads more of its own bytes than a build can hold."
    end
  end

  # The archive as rubyzip sees it: every byte it reads is counted, so an archive that points several
  # of its entries at the same bytes cannot decompress them once per entry.
  class BoundedArchive
    def initialize(io, budget, copies = [])
      @io = io
      @budget = budget
      @copies = copies
    end

    def read(length = nil, outbuf = nil)
      data = length ? @io.read(length) : @io.read
      @budget.add(data.bytesize) if data
      outbuf ? outbuf.replace(data.to_s) : data
    end

    # rubyzip dups the archive for each entry it opens and can raise before handing that copy back,
    # so every copy is kept to be closed with the archive.
    def dup
      copy = self.class.new(@io.dup, @budget, @copies)
      @copies << copy
      copy
    end

    def close_copies = @copies.each { _1.close unless _1.closed? }
    def size = @io.size
    def tell = @io.tell
    def seek(*args) = @io.seek(*args)
    def eof = @io.eof
    def eof? = @io.eof
    def close = @io.close
    def closed? = @io.closed?
  end

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
  rescue StandardError => e
    # A failed unpack must leave nothing behind: a half-written site/ would be served once the
    # player exists. A rejected zip is recorded; any other error is left to the job's retry.
    delete_written_files
    build.update!(site_unpack_error: e.message) if e.is_a?(UnpackError)
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
      written_keys.each_slice(1_000) do |keys|
        result = s3.delete_objects(bucket: S3_BUCKET, delete: { objects: keys.map { { key: _1 } }, quiet: true })
        # A key left behind would be served, so a partial delete fails the run and the retry cleans up.
        raise "Could not delete #{result.errors.size} unpacked files of build #{build.id}" if result.errors.any?
      end
      written_keys.clear
    end

    def download(zip_file)
      Aws::S3::Client.new.get_object(bucket: S3_BUCKET, key: build.storage_key, response_target: zip_file.path)
    end

    def unpack(zip_path)
      entries = check_directory(zip_path)

      s3 = Aws::S3::Client.new
      file_count = 0
      byte_size = 0
      has_index = false

      archive = File.open(zip_path, "rb")
      bounded = BoundedArchive.new(archive, ReadBudget.new(archive_read_budget(archive.size, entries)))
      begin
        # The archive is handed to rubyzip through a counter, so the whole unpack is bounded by what
        # it reads out of it: opening it by path would give rubyzip an IO of its own, unmeasured.
        zip = reading_archive { Zip::File.open_buffer(bounded) }

        files = zip.reject(&:directory?)
        # Every name is checked before anything is copied, so a zip rejected for its layout or its
        # names does not leave a half-written site behind.
        folder = folder_to_strip(files.map { normalize_entry_name(_1.name) })
        paths = files.map { relative_entry_name(_1.name, folder) }
        # Seeking to a local header past the end can raise EINVAL on some filesystems, which would read
        # as a disk error and be retried.
        raise UnpackError, UNREADABLE_ARCHIVE if files.any? { _1.local_header_offset >= archive.size }

        files.zip(paths).each do |entry, path|
          raise UnpackError, "A build cannot contain symlinks: #{shown(entry.name)}." if entry.symlink?
          raise UnpackError, "A build can have at most #{ProductBuild::MAX_SITE_FILES} files." if file_count >= ProductBuild::MAX_SITE_FILES

          written = copy_entry(entry, path, s3, ProductBuild::MAX_SITE_BYTE_SIZE - byte_size)
          file_count += 1
          byte_size += written
          has_index = true if path == "index.html"
        end
      ensure
        bounded.close_copies
        archive.close
      end

      raise UnpackError, "The zip has no index.html at its root, so there is nothing to play." unless has_index

      build.update!(site_unpacked_at: Time.current, site_file_count: file_count, site_byte_size: byte_size, site_unpack_error: nil)
    end

    # rubyzip raises plain NoMethodError and TypeError on some malformed records, not only Zip::Error,
    # so anything it raises while reading the archive is a rejected zip. Those are reported too: a bug of
    # ours here would otherwise look like a run of bad zips. Local disk errors stay retryable.
    def reading_archive
      yield
    rescue UnpackError, SystemCallError
      raise
    rescue StandardError => e
      ErrorNotifier.notify(e) unless e.is_a?(Zip::Error) || e.is_a?(Zlib::Error)
      raise UnpackError, UNREADABLE_ARCHIVE
    end

    # What the unpack may read out of the archive: the archive itself, plus one 32 KB chunk per
    # entry, because the chunk rubyzip reads for an entry runs past it. A build's entries read their
    # own bytes once, so an archive that reads far past this has pointed its entries at the same
    # data, which would otherwise be decompressed once per entry.
    def archive_read_budget(archive_size, entries) = (archive_size + (entries * ARCHIVE_READ_CHUNK)) * 2

    # The entries a build may hold: its files, plus the folder entries an archive carries for them.
    def max_archive_entries = ProductBuild::MAX_SITE_FILES * 2 + ARCHIVE_ENTRY_SLACK

    # Walks the archive's directory without opening it, which is the memory rubyzip is about to spend:
    # the records it holds there are counted and measured, and the walk stops as soon as either budget
    # is passed. A record's name and comment lengths are read from the record itself, which is why the
    # bytes are budgeted next to the count: a handful of entries can carry megabytes of names. Returns
    # the entries found, which is what the read budget is worked out from.
    def check_directory(zip_path)
      File.open(zip_path, "rb") do |file|
        directory = zip_directory(file)
        return 0 if directory.nil?

        walk_directory(file, directory[:offset], directory[:entries])
      end
    end

    # The directory rubyzip will read, as the end-of-directory record it picks describes it: where the
    # records start and how many of them there are. Reading the archive's own description is what
    # keeps the walk and the load from disagreeing — the records are still measured from the record
    # itself, never trusted, but the count says how many have to be there for the archive to be one
    # rubyzip would read at all.
    def zip_directory(file)
      file.seek([file.size - EOCD_SEARCH_WINDOW, 0].max)
      tail = file.read

      if tail.include?(ZIP64_EOCD_SIGNATURE) && tail.include?(ZIP64_EOCD_LOCATOR_SIGNATURE) && (zip64 = tail.rindex(ZIP64_EOCD_SIGNATURE))
        return { offset: tail[zip64 + 48, 8]&.unpack1("Q<"), entries: tail[zip64 + 32, 8]&.unpack1("Q<") }
      end

      eocd = tail.rindex(EOCD_SIGNATURE)
      return nil unless eocd

      { offset: tail[eocd + 16, 4]&.unpack1("V"), entries: tail[eocd + 10, 2]&.unpack1("v") }
    end

    # Counts and measures the records rubyzip is about to load, raising when the archive's directory
    # is not the one it describes, or when either budget is passed.
    def walk_directory(file, offset, declared_entries)
      raise UnpackError, MALFORMED_DIRECTORY if offset.nil? || declared_entries.nil? || offset >= file.size

      file.seek(offset)
      entries = 0
      metadata_bytes = 0

      while entries < declared_entries
        header = file.read(CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE)
        raise UnpackError, MALFORMED_DIRECTORY if header.nil? || header.bytesize < CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE
        raise UnpackError, MALFORMED_DIRECTORY unless header.start_with?(CENTRAL_DIRECTORY_ENTRY_SIGNATURE)

        name_length, extra_length, comment_length = header[28, 6].unpack("vvv")
        record_size = CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE + name_length + extra_length + comment_length
        raise UnpackError, MALFORMED_DIRECTORY if file.pos + record_size - CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE > file.size
        entries += 1
        metadata_bytes += record_size
        raise UnpackError, "The zip has more entries than a build may hold." if entries > max_archive_entries
        raise UnpackError, "The zip's entry names and folders take up more room than a build may hold." if metadata_bytes > ARCHIVE_METADATA_BYTE_BUDGET

        file.seek(record_size - CENTRAL_DIRECTORY_ENTRY_FIXED_SIZE, IO::SEEK_CUR)
      end

      entries
    end

    # Copies one entry into the build's site prefix, stopping as soon as it passes the bytes left in
    # the budget: the length the archive declares for the entry is not trusted.
    def copy_entry(entry, path, s3, remaining_bytes)
      Tempfile.create("entry") do |file|
        file.binmode
        copied = reading_archive { copy_entry_bytes(entry, file, remaining_bytes) }
        if copied > remaining_bytes
          raise UnpackError, "A build's files can unpack to at most #{ProductBuild::MAX_SITE_BYTE_SIZE / 1.gigabyte} GB."
        end

        file.rewind
        key = "#{build.site_prefix}/#{path}"
        # Tracked before the call: a put that times out after S3 stored the object must still be cleaned up.
        written_keys << key
        s3.put_object(
          bucket: S3_BUCKET,
          key:,
          body: file,
          content_length: copied,
          content_type: content_type_for(path),
        )
        copied
      end
    end

    # Copies one entry out of the archive and closes the stream it read it through: rubyzip opens one
    # IO per entry, so leaving them open would hold a descriptor per file in the build.
    def copy_entry_bytes(entry, file, remaining_bytes)
      stream = entry.get_input_stream
      begin
        IO.copy_stream(stream, file, remaining_bytes + 1)
      ensure
        stream.close
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
      path = path.delete_prefix("#{folder}/") if folder
      if "#{build.site_prefix}/#{path}".bytesize > S3_KEY_MAX_BYTES
        raise UnpackError, "The zip has an entry with a name that is too long: #{shown(path)}."
      end

      path
    end

    # The entry's path relative to the site prefix, or an error when the entry tries to leave it.
    def normalize_entry_name(name)
      # rubyzip hands names back as raw bytes whatever the archive's UTF-8 flag says, and S3 keys
      # must be UTF-8.
      name = name.to_s.dup.force_encoding(Encoding::UTF_8)
      raise UnpackError, "The zip has an entry with no name." if name.empty?
      raise UnpackError, "The zip has an entry whose name is not valid UTF-8: #{shown(name)}." unless name.valid_encoding?
      # Control characters cannot go into the XML body of the batched delete that cleans up a failed run;
      # backslashes are path separators on Windows.
      raise UnpackError, "The zip has an entry with an unsafe name: #{shown(name)}." if name.match?(/[\p{Cc}\u{FFFE}\u{FFFF}\\]/)
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
      name.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(/\p{Cc}/) { format("\\x%02X", _1.ord) }.truncate(ENTRY_NAME_MAX_LENGTH)
    end
end
