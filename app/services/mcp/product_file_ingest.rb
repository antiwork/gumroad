# frozen_string_literal: true

module Mcp
  # Copies a file a creator linked in chat into their own attachments prefix (where
  # POST /v2/files/complete puts an upload) and creates the row through WithProductFiles#save_files!.
  # Runs inside the MCP request, which Rack::Timeout ends at 120s, so the download is capped and a
  # larger file still goes through the editor's uploader.
  class ProductFileIngest
    MAX_BYTES = 250.megabytes

    class InvalidUrl < StandardError; end
    class TooLarge < StandardError; end
    class DownloadFailed < StandardError; end

    def initialize(seller:, product:, url:, display_name: nil)
      @seller = seller
      @product = product
      @url = url.to_s.strip
      @display_name = display_name.to_s.strip.presence
    end

    # @return [ProductFile] the file now attached to the product
    def perform
      uri = parse_url
      key = nil
      begin
        key, byte_size = store(uri)
        attach(key, byte_size)
      rescue StandardError
        # The bytes are already in the seller's prefix, so a failed save has to take them with it.
        delete_object(key) if key
        raise
      end
    end

    private
      attr_reader :seller, :product, :url, :display_name

      def parse_url
        normalized = url.start_with?("//") ? "https:#{url}" : url
        uri = URI.parse(normalized)
        raise InvalidUrl if uri.host.blank? || !uri.scheme.in?(%w[http https])

        uri
      rescue URI::InvalidURIError
        raise InvalidUrl
      end

      def store(uri)
        tempfile, content_type = download(uri)
        begin
          filename = filename_with_extension(filename_from(uri), content_type)
          key = "attachments/#{seller.external_id}/#{SecureRandom.hex}/original/#{filename}"
          byte_size = tempfile.size
          Aws::S3::Client.new.put_object(
            bucket: S3_BUCKET,
            key:,
            body: tempfile,
            content_length: byte_size,
            content_type: content_type.presence || "application/octet-stream",
          )
          [key, byte_size]
        ensure
          tempfile.close!
        end
      end

      def download(uri)
        tempfile = Tempfile.new(binmode: true)
        response = SsrfFilter.get(uri.to_s) do |http_response|
          raise TooLarge if http_response["content-length"].to_i > MAX_BYTES

          success = http_response.is_a?(Net::HTTPSuccess)
          received = 0
          http_response.read_body do |chunk|
            received += chunk.bytesize
            raise TooLarge if received > MAX_BYTES

            tempfile.write(chunk) if success
          end
        end
        # A file under the IO buffer size has nothing on disk until it is flushed.
        tempfile.flush
        raise DownloadFailed unless response.is_a?(Net::HTTPSuccess)
        raise DownloadFailed if tempfile.size.zero?

        tempfile.rewind
        [tempfile, response.content_type.to_s]
      rescue StandardError
        tempfile.close!
        raise
      end

      def attach(key, byte_size)
        file_url = "#{S3_BASE_URL}#{key}"
        # Appends to the download list and sets the size the analyze job would only fill in later.
        # delete_missing stays false: this adds a file, it is not a full snapshot of them.
        product.save_files!(
          [{ url: file_url, display_name:, size: byte_size, position: (product.alive_product_files.map(&:position).compact.max || 0) + 1 }],
          [],
          delete_missing: false
        )
        product.generate_product_files_archives!
        product.alive_product_files.find { |file| file.url == file_url }
      end

      # URLs like ".../watch" have no filename to keep, and the display name a creator typed is
      # user input, so only a sanitized basename is allowed in the key.
      def filename_from(uri)
        basename = File.basename(uri.path.to_s)
        name = basename.presence && basename != "/" ? basename : display_name || "file"
        ActiveStorage::Filename.new(name).sanitized.presence || "file"
      end

      # ProductFile reads its type from the extension, and a link like ".../watch" has none.
      def filename_with_extension(filename, content_type)
        return filename if File.extname(filename).present?

        extension = MiniMime.lookup_by_content_type(content_type.to_s)&.extension
        extension.present? ? "#{filename}.#{extension}" : filename
      end

      def delete_object(key)
        Aws::S3::Client.new.delete_object(bucket: S3_BUCKET, key:)
      rescue StandardError => e
        Rails.logger.error("Mcp::ProductFileIngest failed to delete #{key}: #{e.message}")
      end
  end
end
