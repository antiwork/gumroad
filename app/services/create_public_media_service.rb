# frozen_string_literal: true

# CreatePublicMediaService ingests a seller's own image file and hosts it on Gumroad's
# public storage so it can be displayed on the seller's public pages (the profile and product
# custom-HTML landing pages). Those pages render inside a sandbox whose Content-Security-Policy only
# allows images/media from Gumroad's own CDN hosts (see RendersCustomHtmlPages::CUSTOM_HTML_CSP), so
# an off-platform file URL renders as a broken image — the file has to be re-hosted on our public
# storage first. This service is that ingestion path, used by the public v2 media endpoint (and,
# through it, the store agent's upload_media tool — the failure that motivated this: a seller asked
# the agent to put her logo on her landing page and there was no tool that could host the image).
#
# The file arrives either as a remote URL we download server-side (the common case for the agent,
# where the seller pastes a link in chat) or as an already-uploaded ActiveStorage signed blob id.
# Either way the file is:
#   - fetched with SSRF protection — the URL is seller/LLM-supplied, so a naive fetch could be
#     pointed at internal hosts or redirected somewhere private,
#   - type-checked by content sniffing (magic bytes via Marcel), never by file extension or the
#     remote server's Content-Type header, and limited to images that are safe to serve publicly
#     (SVG is excluded: it's scriptable and would be served from a Gumroad-controlled public host),
#   - size-capped — images render inline on landing pages, so this synchronous upload path stays
#     bounded,
#   - run through the existing content moderation strategies BEFORE the record is created, because
#     the hosted URL lives on a Gumroad domain and flagged content would look Gumroad-endorsed.
#
# Audio/video are deliberately out of scope until there is real media-byte moderation for them; a
# filename-only moderation pass is not enough for Gumroad-hosted public media.
#
# On success the file is stored as a PublicFile owned by (and attached to) the seller and served
# from the public storage CDN — the same host the custom-page CSP already allowlists, so the
# returned URL renders on landing pages with no CSP changes.
class CreatePublicMediaService
  Result = Struct.new(:success, :error_message, :public_file, keyword_init: true) do
    def success? = success == true
  end

  # Only media that browsers display/play inline. image/svg+xml is deliberately excluded even
  # though it is an image type: an SVG is a scriptable document, and everything this service stores
  # is served publicly from a Gumroad-controlled host.
  ALLOWED_CONTENT_TYPE_PREFIXES = %w[image/].freeze
  DISALLOWED_CONTENT_TYPES = %w[image/svg+xml].freeze

  # Images render inline on landing pages, so they get a small cap (mirrors the product thumbnail
  # cap's order of magnitude). This download happens synchronously inside a web request, so it stays bounded.
  MAX_IMAGE_BYTES = 10.megabytes

  # Simple ceiling so public hosting can't be farmed as free unlimited storage. Counts only the
  # seller's own media files (resource = the seller), not the per-product public files.
  MAX_ALIVE_MEDIA_FILES_PER_SELLER = 500

  MODERATION_NOUN = "file"

  RemoteFileTooLarge = Class.new(StandardError)
  BlobNotEligible = Class.new(StandardError)
  QuotaExceeded = Class.new(StandardError)

  # @param seller [User] the store owner the file will belong to
  # @param url [String, nil] a public URL to download the file from (SSRF-guarded)
  # @param signed_blob_id [String, nil] an ActiveStorage signed blob id from a prior direct upload
  # @param name [String, nil] optional display name for the file
  def initialize(seller:, url: nil, signed_blob_id: nil, name: nil)
    @seller = seller
    @url = url.presence
    @signed_blob_id = signed_blob_id.presence
    @name = name.presence
  end

  # @return [Result]
  def process
    return failure("Please provide a url or signed_blob_id.") if url.blank? && signed_blob_id.blank?
    # Cheap fast-fail before we spend a download on a request that can't succeed. The
    # authoritative, race-safe check happens again under a lock right before the record is saved.
    if alive_media_files.count >= MAX_ALIVE_MEDIA_FILES_PER_SELLER
      return failure(quota_error_message)
    end

    blob = signed_blob_id.present? ? existing_blob : download_blob_from_url
    return failure("The signed_blob_id is invalid or expired.") if blob.nil?

    begin
      content_type = blob.content_type.to_s
      error = content_type_error(content_type) ||
        size_error_for(content_type, blob.byte_size.to_i) ||
        moderation_error_for(blob, content_type)
      if error
        # The blob is already on the PUBLIC bucket, so a rejected file isn't just storage waste —
        # it's a live URL. Purge it so a disallowed or moderation-flagged file never stays hosted.
        purge_unattached(blob)
        return failure(error)
      end

      public_file = build_public_file(blob)
      if save_within_quota(public_file)
        Result.new(success: true, public_file:)
      else
        purge_unattached(blob)
        failure(public_file.errors.full_messages.to_sentence.presence || "The file couldn't be saved.")
      end
    rescue StandardError
      # Same cleanup on unexpected errors — never leave an orphaned public blob behind.
      purge_unattached(blob)
      raise
    end
  rescue URI::InvalidURIError, Addressable::URI::InvalidURIError,
         SsrfFilter::CRLFInjection, SsrfFilter::InvalidUriScheme,
         SsrfFilter::PrivateIPAddress, SsrfFilter::TooManyRedirects, SsrfFilter::UnresolvedHostname
    failure("Please provide a valid public URL.")
  rescue RemoteFileTooLarge
    failure("That file is too large. Images can be up to #{MAX_IMAGE_BYTES / 1.megabyte} MB.")
  rescue QuotaExceeded
    failure(quota_error_message)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound, BlobNotEligible
    # BlobNotEligible gets the same reply as a bad signature on purpose: a caller probing with
    # someone else's signed id shouldn't learn that the blob exists but belongs to another account.
    failure("The signed_blob_id is invalid or expired.")
  rescue ActiveStorage::FileNotFoundError, *INTERNET_EXCEPTIONS
    failure("We couldn't download that file, please check the URL and try again.")
  end

  private
    attr_reader :seller, :url, :signed_blob_id, :name

    def failure(message)
      Result.new(success: false, error_message: message)
    end

    # Purge a blob that ended up rejected or orphaned, but never one another record already
    # attached (a signed_blob_id could in principle point at a blob that's in use elsewhere).
    def purge_unattached(blob)
      blob.purge if blob.present? && blob.persisted? && blob.attachments.none?
    rescue StandardError => e
      Rails.logger.error("CreatePublicMediaService failed to purge rejected blob #{blob&.id}: #{e.message}")
    end

    def alive_media_files
      PublicFile.alive.where(seller:, resource: seller)
    end

    # The early quota check in #process is a read-then-act on a plain count, so two concurrent
    # uploads could both pass it and push the seller past the cap. Re-check under a row lock on
    # the seller so the count and the insert happen atomically — concurrent requests for the same
    # seller serialize here, and the loser gets the same quota error the early check produces.
    def save_within_quota(public_file)
      PublicFile.transaction do
        seller.lock!
        raise QuotaExceeded if alive_media_files.count >= MAX_ALIVE_MEDIA_FILES_PER_SELLER
        public_file.save
      end
    end

    def quota_error_message
      "You've reached the limit of #{MAX_ALIVE_MEDIA_FILES_PER_SELLER} uploaded files. Delete some before uploading more."
    end

    def existing_blob
      # find_signed! raises InvalidSignature/RecordNotFound for tampered or expired ids — both are
      # rescued above and reported as an invalid signed_blob_id.
      blob = ActiveStorage::Blob.find_signed!(signed_blob_id)
      # A signed blob id proves the id wasn't tampered with — it says nothing about WHO uploaded
      # the blob. Without an ownership check, anyone holding another seller's signed id could
      # attach that seller's upload to their own account. The v2 direct-upload endpoint stamps the
      # uploader's user id into the blob's metadata; only accept blobs stamped for this seller.
      # Blobs already attached to another record are also refused — this path is for ingesting a
      # fresh upload, not for aliasing files that already belong somewhere else.
      uploaded_by = blob.metadata.with_indifferent_access[:uploaded_by_user_id]
      raise BlobNotEligible unless uploaded_by.present? && uploaded_by.to_s == seller.id.to_s
      raise BlobNotEligible if blob.attachments.exists?

      # Direct-upload blobs carry the client-declared content type; identify from the actual bytes
      # so the allowlist below judges what the file IS, not what the uploader claimed.
      blob.identify unless blob.identified?
      blob
    end

    # Download the remote file to a tempfile with SSRF protection and a hard size ceiling, then
    # store it as a blob. The size is enforced while streaming (both via the Content-Length header
    # and by counting actual bytes) so a file larger than the 10 MB image cap is cut off
    # mid-download instead of being fully downloaded (and uploaded to public storage) only to be
    # rejected by the size check afterwards. Mirrors the hardened fetch the product thumbnail's
    # URL path already uses (Thumbnail#url=).
    def download_blob_from_url
      normalized_url = normalize_url(url)
      uri = URI.parse(normalized_url)
      raise URI::InvalidURIError, "URL '#{normalized_url}' is not a web url" unless uri.scheme.in?(%w[http https])
      raise URI::InvalidURIError, "URL must include a valid host" if uri.host.blank?

      tempfile = Tempfile.new(binmode: true)
      begin
        response = SsrfFilter.get(normalized_url) do |http_response|
          raise RemoteFileTooLarge if http_response["content-length"].to_i > MAX_IMAGE_BYTES

          write_file = http_response.is_a?(Net::HTTPSuccess)
          received_bytes = 0
          byte_limit = MAX_IMAGE_BYTES
          http_response.read_body do |chunk|
            received_bytes += chunk.bytesize
            raise RemoteFileTooLarge if received_bytes > byte_limit

            tempfile.write(chunk) if write_file
          end
        end
        raise ActiveStorage::FileNotFoundError unless response.is_a?(Net::HTTPSuccess)

        tempfile.rewind
        # Sniff the real content type from the file bytes. The remote server's header is used only
        # as a hint — a mislabeled or disguised file is classified by what it actually contains.
        content_type = Marcel::MimeType.for(tempfile, name: filename_from(uri), declared_type: response.content_type)
        tempfile.rewind
        ActiveStorage::Blob.create_and_upload!(
          io: tempfile,
          filename: filename_with_extension(filename_from(uri), content_type),
          content_type:,
        )
      ensure
        tempfile.close!
      end
    end

    def normalize_url(raw)
      value = raw.to_s
      value = "https:#{value}" if value.start_with?("//")
      value = Addressable::URI.escape(value) unless URI::ABS_URI.match?(value)
      value
    end

    def filename_from(uri)
      base = File.basename(uri.path.to_s)
      base.presence && base != "/" ? base : "media"
    end

    # PublicFile derives its file_type (and from it the image/audio/video file_group) from the
    # filename's extension, so make sure there is one — URLs like ".../logo" have none. The
    # extension comes from the SNIFFED content type, keeping it truthful to the actual bytes.
    def filename_with_extension(filename, content_type)
      return filename if File.extname(filename).present?

      extension = MiniMime.lookup_by_content_type(content_type.to_s)&.extension
      extension.present? ? "#{filename}.#{extension}" : filename
    end

    def content_type_error(content_type)
      allowed = ALLOWED_CONTENT_TYPE_PREFIXES.any? { |prefix| content_type.start_with?(prefix) } &&
        !DISALLOWED_CONTENT_TYPES.include?(content_type)
      allowed ? nil : "Only image files can be uploaded."
    end

    def size_error_for(content_type, byte_size)
      limit = MAX_IMAGE_BYTES
      return nil if byte_size <= limit

      "That file is too large. Images can be up to #{limit / 1.megabyte} MB."
    end

    # Screen the file with the same moderation strategies that gate product publishing, BEFORE the
    # PublicFile record exists. The blob itself is already on public storage at this point (that's
    # unavoidable — the classifier needs a fetchable URL), but a flagged blob is purged immediately
    # by the caller's ensure-style cleanup, so it never gets a stable, discoverable public_id.
    # Mirrors ModerateRecordService: feature-flagged, verified sellers exempt, blocklist first.
    def moderation_error_for(blob, content_type)
      return nil unless Feature.active?(:content_moderation)
      return nil if seller&.verified?

      text = [name, blob.filename.to_s].compact_blank.uniq.join(" ")
      image_urls = content_type.start_with?("image/") ? [blob.url] : []

      strategies = [
        ContentModeration::Strategies::BlocklistStrategy.new(text:, image_urls:),
        ContentModeration::Strategies::ClassifierStrategy.new(text:, image_urls:),
        ContentModeration::Strategies::PromptStrategy.new(text:, image_urls:),
      ]

      strategies.each do |strategy|
        result = strategy.perform
        if result.status == "flagged"
          return ContentModeration::ModerateRecordService.seller_message(result.reasoning, MODERATION_NOUN)
        end
      end

      nil
    end

    def build_public_file(blob)
      public_file = PublicFile.new(seller:, resource: seller)
      public_file.display_name = name if name.present?
      public_file.file.attach(blob.signed_id)
      public_file
    end
end
