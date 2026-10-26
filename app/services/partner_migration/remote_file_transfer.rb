# frozen_string_literal: true

# Copies a file from a partner's download URL into the seller's attachments folder on S3, the same
# place the API's presigned uploads go. SsrfFilter blocks private and internal addresses, also after
# redirects. The body streams to a tempfile with a size limit enforced while it downloads, so an
# oversized file never fills the disk or memory.
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

  # Streams `url` into a tempfile, yields the tempfile and a safe filename, and deletes the tempfile.
  def self.download(url, max_bytes:)
    uri = URI.parse(url)
    raise Error, "Only https URLs are supported." unless uri.is_a?(URI::HTTPS)

    tempfile = Tempfile.new("partner-migration", binmode: true)
    begin
      content_disposition = stream(url, tempfile, max_bytes)
      tempfile.flush
      tempfile.rewind
      yield tempfile, filename_for(uri, content_disposition, tempfile)
    ensure
      tempfile.close!
    end
  end

  # Returns the response's Content-Disposition header.
  def self.stream(url, tempfile, max_bytes)
    too_large = "The file is larger than #{ActiveSupport::NumberHelper.number_to_human_size(max_bytes)}."
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_DOWNLOAD_DURATION
    response = SsrfFilter.get(url, scheme_whitelist: ALLOWED_SCHEMES) do |http_response|
      raise Error, too_large if http_response["content-length"].to_i > max_bytes

      write_file = http_response.is_a?(Net::HTTPSuccess)
      received_bytes = 0
      http_response.read_body do |chunk|
        received_bytes += chunk.bytesize
        raise Error, too_large if received_bytes > max_bytes
        raise TemporaryError, "The file download took longer than #{MAX_DOWNLOAD_DURATION.inspect}." if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        tempfile.write(chunk) if write_file
      end
    end
    return response["content-disposition"] if response.is_a?(Net::HTTPSuccess)
    raise TemporaryError, "The file download failed with HTTP #{response.code}." if response.code.start_with?("5") || TEMPORARY_HTTP_CODES.include?(response.code)

    raise Error, "The file download failed with HTTP #{response.code}."
  end

  # The Content-Disposition filename wins over the URL path. ProductFile reads the file type from the
  # extension, so a name without one gets the extension of the detected content type.
  def self.filename_for(uri, content_disposition, tempfile)
    disposition_name = content_disposition.to_s[/filename\*=UTF-8''([^;]+)/i, 1] || content_disposition.to_s[/filename="?([^";]+)"?/i, 1]
    name = CGI.unescape(disposition_name || File.basename(uri.path.to_s)).gsub(/[^\w.\- ]/, "_").strip
    name = "file" if name.blank? || name.match?(/\A\.+\z/)
    if File.extname(name).blank?
      name += Rack::Mime::MIME_TYPES.invert[Marcel::MimeType.for(tempfile)].to_s
      tempfile.rewind
    end
    name.last(MAX_FILENAME_LENGTH)
  end
  private_class_method :stream, :filename_for

  def initialize(seller:, url:)
    @seller = seller
    @url = url
  end

  # Returns the S3 URL to pass to SaveFilesService.
  def perform
    self.class.download(url, max_bytes: MAX_BYTES) do |tempfile, filename|
      key = "attachments/#{seller.external_id}/#{SecureRandom.hex}/original/#{filename}"
      content_type = Marcel::MimeType.for(Pathname.new(tempfile.path), name: filename)
      Aws::S3::Resource.new.bucket(S3_BUCKET).object(key).upload_file(tempfile.path, content_type:)
      "#{S3_BASE_URL}#{key}"
    end
  end

  private
    attr_reader :seller, :url
end
