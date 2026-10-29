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
      uri = parse_source_uri
      key = nil
      begin
        key, byte_size = store(uri)
        attach(key, byte_size)
      rescue StandardError
        discard_upload(key) if key
        raise
      end
    end

    private
      attr_reader :seller, :product, :url, :display_name

      def parse_source_uri
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
        stored_url = "#{S3_BASE_URL}#{key}"
        # Appends to the download list and sets the size the analyze job would only fill in later.
        # delete_missing stays false: this adds a file, it is not a full snapshot of them.
        product.save_files!(
          [{ url: stored_url, display_name:, size: byte_size, position: (product.alive_product_files.map(&:position).compact.max || 0) + 1 }],
          [],
          delete_missing: false
        )
        file = product.alive_product_files.find { |product_file| product_file.url == stored_url }
        ensure_buyers_see(file) if file
        product.generate_product_files_archives!
        file
      end

      # Buyers get the files embedded in their content page, and a page that embeds none shows all
      # of them (UrlRedirect#alive_product_files), so only a page already gating by embed needs the
      # new one. A per-variant product delivers each variant's own files, hence the links.
      def ensure_buyers_see(file)
        append_embed(product.alive_rich_contents, file)
        return if product.has_product_level_rich_content?

        product.alive_variants.each do |variant|
          append_embed(variant.alive_rich_contents, file)
          variant.product_files << file unless variant.product_files.include?(file)
        end
      end

      def append_embed(pages, file)
        pages = pages.to_a
        return if pages.empty? || pages.any? { _1.embedded_product_file_ids_in_order.include?(file.id) }
        return unless pages.any? { _1.embedded_product_file_ids_in_order.any? }

        first_page = pages.min_by(&:position)
        first_page.update!(description: first_page.description.to_a + [file_embed_node(file)])
      end

      def file_embed_node(file)
        { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
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

      # save_files! has already committed the row when a callback raises, and the file is in use then.
      def discard_upload(key)
        return if ProductFile.alive.exists?(url: "#{S3_BASE_URL}#{key}")

        delete_object(key)
      end

      def delete_object(key)
        Aws::S3::Client.new.delete_object(bucket: S3_BUCKET, key:)
      rescue StandardError => e
        Rails.logger.error("Mcp::ProductFileIngest failed to delete #{key}: #{e.message}")
      end
  end
end
