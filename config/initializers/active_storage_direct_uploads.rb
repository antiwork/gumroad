# frozen_string_literal: true

# ActiveStorage::DirectUploadsController hands the permitted blob params straight to
# Blob.create_before_direct_upload!, whose required keywords raise ArgumentError when a key is
# absent — so a reservation without `checksum` answered 500. A malformed body is a client error;
# answer 400 like Api::V2::DirectUploadsController does.
module ActiveStorageDirectUploadsBadRequest
  REQUIRED_BLOB_KEYS = [:filename, :byte_size, :checksum].freeze
  PERMITTED_BLOB_KEYS = [:filename, :byte_size, :checksum, :content_type, :metadata].freeze

  def create
    # Check the PERMITTED values, the same way the engine's own controller builds its arguments:
    # `permit` drops a key whose value is not a permitted scalar (e.g. `filename: ["cover.png"]`),
    # so testing the raw body would let a reservation through that still reaches
    # create_before_direct_upload! without the keyword and raises.
    blob = params[:blob]
    blob_args = blob.is_a?(ActionController::Parameters) ? blob.permit(*PERMITTED_BLOB_KEYS) : nil
    unless blob_args && REQUIRED_BLOB_KEYS.all? { |key| blob_args[key].present? }
      return render json: { error: "blob must include filename, byte_size and checksum" }, status: :bad_request
    end

    super
  end
end

# Serving headers for objects stored through direct uploads: images, audio and video keep their type
# inline, and everything else is stored as a binary attachment.
module ActiveStorageDirectUploadServing
  INLINE_CONTENT_TYPES = %w[image/png image/jpeg image/jpg image/gif image/webp image/avif image/heic image/heif image/bmp image/tiff].freeze
  INLINE_MEDIA_TYPE = %r{\A(?:audio|video)/[a-z0-9][a-z0-9.-]*\z}

  def service_url_for_direct_upload(expires_in: ActiveStorage.service_urls_expire_in)
    serving = direct_upload_serving
    # Only the S3 service below signs the disposition; other services take the content type alone.
    serving = serving.slice(:content_type) unless service.is_a?(ActiveStorage::Service::S3Service)
    service.url_for_direct_upload(key, expires_in:, content_length: byte_size, checksum:, custom_metadata:, **serving)
  end

  def service_headers_for_direct_upload
    service.headers_for_direct_upload(key, content_length: byte_size, checksum:, custom_metadata:, **direct_upload_serving)
  end

  private
    def direct_upload_serving
      media_type = content_type.to_s.split(";").first.to_s.strip.downcase
      if INLINE_CONTENT_TYPES.include?(media_type) || INLINE_MEDIA_TYPE.match?(media_type)
        { content_type: media_type, filename:, disposition: :inline }
      else
        { content_type: ActiveStorage.binary_content_type, filename:, disposition: :attachment }
      end
    end
end

# Sign Content-Disposition into the presigned PUT for attachments, so the stored value matches the returned header.
module ActiveStorageS3SignedDirectUploadDisposition
  def url_for_direct_upload(key, expires_in:, content_type:, content_length:, checksum:, custom_metadata: {}, filename: nil, disposition: nil)
    return super(key, expires_in:, content_type:, content_length:, checksum:, custom_metadata:) unless filename && disposition == :attachment

    instrument :url, key: key do |payload|
      payload[:url] = object_for(key).presigned_url(
        :put,
        expires_in: expires_in.to_i,
        content_type:,
        content_length:,
        content_md5: checksum,
        content_disposition: content_disposition_with(type: disposition, filename:),
        metadata: custom_metadata,
        whitelist_headers: ["content-length"],
        **upload_options
      )
    end
  end
end

Rails.application.config.to_prepare do
  ActiveStorage::DirectUploadsController.prepend(ActiveStorageDirectUploadsBadRequest)
  ActiveStorage::Blob.prepend(ActiveStorageDirectUploadServing)
end

require "active_storage/service/s3_service"
ActiveStorage::Service::S3Service.prepend(ActiveStorageS3SignedDirectUploadDisposition)
