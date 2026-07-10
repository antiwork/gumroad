# frozen_string_literal: true

class Api::V2::DirectUploadsController < Api::V2::BaseController
  include ActiveStorage::SetCurrent

  ALLOWED_CONTENT_TYPES = /\A(?:image\/(?:jpeg|jpg|png|gif)|video\/[a-z0-9.+-]+)\z/i
  REQUIRED_BLOB_ARGS = [:filename, :byte_size, :checksum].freeze
  MAX_FILE_SIZE_GB = 20
  MAX_FILE_SIZE = MAX_FILE_SIZE_GB.gigabytes

  # A reservation made with `purpose=media` is destined for the public media library
  # (POST /v2/media with a signed_blob_id → CreatePublicMediaService). That pipeline accepts
  # audio too, and enforces much smaller size caps than the 20 GB product-file default — so the
  # reservation mirrors those caps up front. Without this, a caller could reserve a 20 GB video
  # blob only to have /v2/media reject it after the whole upload finished, or couldn't upload
  # audio at all. Content types and caps intentionally mirror CreatePublicMediaService: any
  # image/audio/video subtype except SVG, which is scriptable and would be served from a
  # Gumroad-controlled public host.
  MEDIA_ALLOWED_CONTENT_TYPES = /\A(?:image|audio|video)\/[a-z0-9.+-]+\z/i
  MEDIA_DISALLOWED_CONTENT_TYPES = CreatePublicMediaService::DISALLOWED_CONTENT_TYPES
  MEDIA_MAX_IMAGE_SIZE = CreatePublicMediaService::MAX_IMAGE_BYTES
  MEDIA_MAX_AUDIO_VIDEO_SIZE = CreatePublicMediaService::MAX_AUDIO_VIDEO_BYTES

  before_action { doorkeeper_authorize! :edit_products }

  def create
    blob_args = direct_upload_blob_args
    missing_blob_arg = REQUIRED_BLOB_ARGS.find { |key| !blob_args.key?(key) }
    return error_400("#{missing_blob_arg} is required") if missing_blob_arg.present?
    return error_400("byte_size is required") if blob_args[:byte_size].to_i <= 0
    size_error = byte_size_error(blob_args)
    return error_400(size_error) if size_error.present?
    return error_400(content_type_error_message) unless allowed_content_type?(blob_args[:content_type])

    # Record who reserved this blob. A signed blob id alone doesn't identify the uploader, so
    # consumers that accept one (e.g. CreatePublicMediaService for the media library) use this
    # stamp to make sure a seller can only attach blobs they uploaded themselves.
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      **blob_args,
      metadata: { uploaded_by_user_id: current_resource_owner.id },
    )

    render json: direct_upload_json(blob)
  rescue ActionController::ParameterMissing => e
    error_400(e.message)
  rescue ActiveRecord::RecordInvalid => e
    error_400(e.record.errors.full_messages.to_sentence)
  end

  private
    def direct_upload_blob_args
      params.require(:blob).permit(:filename, :byte_size, :checksum, :content_type).to_h.symbolize_keys
    end

    # `purpose=media` switches this endpoint into media-library mode: audio is allowed, and the
    # media pipeline's smaller caps apply. Every other caller (product file uploads) keeps the
    # original allowlist and 20 GB cap — the parameter is opt-in so existing integrations are
    # untouched.
    def media_purpose?
      params[:purpose].to_s == "media"
    end

    def byte_size_error(blob_args)
      byte_size = blob_args[:byte_size].to_i
      if media_purpose?
        # Images render inline on landing pages so they get a much smaller cap than audio/video;
        # same split CreatePublicMediaService enforces when the blob is later ingested.
        limit = blob_args[:content_type].to_s.match?(/\Aimage\//i) ? MEDIA_MAX_IMAGE_SIZE : MEDIA_MAX_AUDIO_VIDEO_SIZE
        return "byte_size exceeds the #{limit / 1.megabyte} MB maximum for media uploads" if byte_size > limit
      elsif byte_size > MAX_FILE_SIZE
        return "byte_size exceeds the #{MAX_FILE_SIZE_GB} GB maximum"
      end
      nil
    end

    def allowed_content_type?(content_type)
      return false unless content_type.is_a?(String)
      if media_purpose?
        content_type.match?(MEDIA_ALLOWED_CONTENT_TYPES) && !MEDIA_DISALLOWED_CONTENT_TYPES.include?(content_type.downcase)
      else
        content_type.match?(ALLOWED_CONTENT_TYPES)
      end
    end

    def content_type_error_message
      if media_purpose?
        "content_type must be an image, audio, or video type."
      else
        "content_type must be JPEG, PNG, GIF, or video."
      end
    end

    def direct_upload_json(blob)
      blob.as_json(root: false, methods: :signed_id).merge(
        direct_upload: {
          url: blob.service_url_for_direct_upload,
          headers: blob.service_headers_for_direct_upload
        }
      )
    end
end
