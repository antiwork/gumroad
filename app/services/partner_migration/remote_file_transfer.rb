# frozen_string_literal: true

# Copies a file from a partner's download URL into the seller's attachments folder on S3, the same
# place the API's presigned uploads go. SsrfFilter blocks private and internal addresses, also after
# redirects. A product file streams straight into a multipart upload, so even a file of tens of GB is
# never written to the worker's disk whole, only as small part buffers; covers and avatars go
# through a small tempfile instead. The size
# limit is enforced while the body arrives, so an oversized file never fills the disk or memory.
class PartnerMigration::RemoteFileTransfer
  class Error < StandardError; end
  # A response that can succeed later. It is not an Error, so the import job lets Sidekiq retry it.
  class TemporaryError < StandardError; end

  MAX_BYTES = WithFileProperties::MAX_DOWNLOAD_SIZE
  MAX_FILENAME_LENGTH = 200
  # SsrfFilter allows http by default, also when an https URL redirects.
  ALLOWED_SCHEMES = %w[https].freeze
  TEMPORARY_HTTP_CODES = %w[408 425 429].freeze
  # Net::HTTP's read timeout stops a host that goes silent, but not one that sends a byte now and then.
  MAX_DOWNLOAD_DURATION = 3.hours
  # Each part is buffered in its own small tempfile, as in UpdateProductFilesArchiveWorker: about
  # (UPLOAD_THREADS + 1) x UPLOAD_PART_SIZE of disk per transfer, never the whole file, and no memory
  # growth on the nodes that run buyer-facing jobs. S3 allows 10,000 parts, so this part size covers
  # objects up to 160 GB, above MAX_BYTES.
  UPLOAD_PART_SIZE = 16.megabytes
  UPLOAD_THREADS = 4
  # Enough bytes for Marcel to identify the type of a file whose name has no extension.
  SNIFF_BYTES = 64.kilobytes
  MAX_REDIRECT_BODY_BYTES = 1.megabyte

  # One download's time limit, shared by every response that it receives, redirects included.
  TimeLimit = Struct.new(:duration, :deadline) do
    def self.start(duration) = new(duration, Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration)

    def check!
      raise TemporaryError, "The file download took longer than #{duration.inspect}." if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
  end

  # Streams `url` into a tempfile, yields the tempfile and a safe filename, and deletes the tempfile.
  def self.download(url, max_bytes:, max_duration: MAX_DOWNLOAD_DURATION)
    uri = URI.parse(url)
    raise Error, "Only https URLs are supported." unless uri.is_a?(URI::HTTPS)

    tempfile = Tempfile.new("partner-migration", binmode: true)
    begin
      content_disposition = stream(url, tempfile, max_bytes, max_duration)
      tempfile.flush
      tempfile.rewind
      yield tempfile, filename_for(uri, content_disposition, tempfile)
    ensure
      tempfile.close!
    end
  end

  # Returns the response's Content-Disposition header.
  def self.stream(url, tempfile, max_bytes, max_duration = MAX_DOWNLOAD_DURATION)
    time_limit = TimeLimit.start(max_duration)
    response = get(url, time_limit) do |http_response|
      # Net::HTTP retries a request once after a broken connection, and that calls this block again.
      tempfile.rewind
      tempfile.truncate(0)
      chunks = checked_chunks(http_response, max_bytes, time_limit)
      loop { tempfile.write(chunks.next) }
    end
    response["content-disposition"]
  end

  # Yields a successful response. SsrfFilter passes every response here, redirects included, and
  # follows the redirects itself. Net::HTTP reads any body that the block leaves unread into memory,
  # with no limit, so a redirect's body is read and discarded under a limit, and a failure raises
  # before its body is read, which closes the connection.
  def self.get(url, time_limit, &block)
    # Net::HTTP otherwise accepts a short response as a complete file.
    response = SsrfFilter.get(url, scheme_whitelist: ALLOWED_SCHEMES, http_options: { ignore_eof: false }) do |http_response|
      if http_response.is_a?(Net::HTTPRedirection)
        too_large = "The redirect page is larger than #{ActiveSupport::NumberHelper.number_to_human_size(MAX_REDIRECT_BODY_BYTES)}."
        next checked_chunks(http_response, MAX_REDIRECT_BODY_BYTES, time_limit, too_large:).each { }
      end
      raise_for_failure(http_response) unless http_response.is_a?(Net::HTTPSuccess)

      block.call(http_response)
    end
    raise_for_failure(response) unless response.is_a?(Net::HTTPSuccess)
    response
  end

  def self.raise_for_failure(response)
    raise TemporaryError, "The file download failed with HTTP #{response.code}." if response.code.start_with?("5") || TEMPORARY_HTTP_CODES.include?(response.code)

    raise Error, "The file download failed with HTTP #{response.code}."
  end

  # The body's chunks, checked against the size and time limits as they arrive. An Enumerator, so the
  # caller can read the first chunk before it decides where the rest goes.
  def self.checked_chunks(http_response, max_bytes, time_limit, too_large: "The file is larger than #{ActiveSupport::NumberHelper.number_to_human_size(max_bytes)}.")
    raise Error, too_large if http_response["content-length"].to_i > max_bytes

    received_bytes = 0
    Enumerator.new do |chunks|
      http_response.read_body do |chunk|
        received_bytes += chunk.bytesize
        raise Error, too_large if received_bytes > max_bytes

        time_limit.check!

        chunks << chunk
      end
    end
  end

  # The Content-Disposition filename wins over the URL path. ProductFile reads the file type from the
  # extension, so a name without one gets the extension of the type detected from `head`, an IO at
  # the start of the file.
  def self.filename_for(uri, content_disposition, head)
    disposition_name = content_disposition.to_s[/filename\*=UTF-8''([^;]+)/i, 1] || content_disposition.to_s[/filename="?([^";]+)"?/i, 1]
    # Path segments and RFC 5987 values keep "+" literal, unlike form encoding. A legacy name such as
    # "caf%E9.zip" decodes to bytes that are not UTF-8, which gsub rejects.
    name = CGI.unescapeURIComponent(disposition_name || File.basename(uri.path.to_s)).scrub("_").gsub(/[^\w.\- ]/, "_").strip
    name = "file" if name.blank? || name.match?(/\A\.+\z/)
    if File.extname(name).blank?
      name += Rack::Mime::MIME_TYPES.invert[Marcel::MimeType.for(head)].to_s
      head.rewind
    end
    name.last(MAX_FILENAME_LENGTH)
  end
  private_class_method :stream, :raise_for_failure

  def initialize(seller:, url:)
    @seller = seller
    @url = url
  end

  # Returns the S3 URL to pass to SaveFilesService.
  def perform
    uri = URI.parse(url)
    raise Error, "Only https URLs are supported." unless uri.is_a?(URI::HTTPS)

    key = nil
    time_limit = TimeLimit.start(MAX_DOWNLOAD_DURATION)
    self.class.get(url, time_limit) do |http_response|
      chunks = self.class.checked_chunks(http_response, MAX_BYTES, time_limit)
      # The start of the file identifies its type, which can decide the filename, and so the key.
      head = +""
      while head.bytesize < SNIFF_BYTES && (chunk = next_chunk(chunks))
        head << chunk
      end
      filename = self.class.filename_for(uri, http_response["content-disposition"], StringIO.new(head))
      key = "attachments/#{seller.external_id}/#{SecureRandom.hex}/original/#{filename}"
      upload(key, head, chunks, Marcel::MimeType.for(StringIO.new(head), name: filename))
    end
    raise Error, "The file download returned no file." if key.nil?

    "#{S3_BASE_URL}#{key}"
  end

  private
    attr_reader :seller, :url

    def next_chunk(chunks)
      chunks.next
    rescue StopIteration
      nil
    end

    def upload(key, head, chunks, content_type)
      object = Aws::S3::Resource.new.bucket(S3_BUCKET).object(key)
      # A multipart upload needs at least one part.
      return object.put(body: head, content_type:) if head.empty?

      failure = nil
      object.upload_stream(content_type:, part_size: UPLOAD_PART_SIZE, thread_count: UPLOAD_THREADS, tempfile: true) do |upload|
        # The SDK's pipe would otherwise convert the bytes to the default external encoding.
        upload.binmode
        upload.write(head)
        while (chunk = next_chunk(chunks))
          upload.write(chunk)
        end
      rescue StandardError => e
        failure = e
        raise
      end
    rescue Aws::S3::MultipartUploadError => e
      # The SDK aborts the upload, so S3 keeps no partial file, and wraps the error that stopped it.
      # The import job needs that error's class to decide whether a retry can fix it, so this block's
      # own error wins, also when the abort fails too. A failed part closes the pipe, so this block's
      # write then fails with a pipe error; that case raises the part's own error, as
      # UpdateProductFilesArchiveWorker does. A killed worker cannot abort; the bucket's lifecycle rule
      # removes unfinished multipart uploads after 7 days.
      pipe_closed = failure.nil? || failure.is_a?(Errno::EPIPE) || (failure.is_a?(IOError) && !failure.is_a?(EOFError))
      raise failure unless pipe_closed

      raise(e.errors.find { !_1.is_a?(IOError) && !_1.is_a?(Errno::EPIPE) } || e)
    end
end
