# frozen_string_literal: true

class Api::V2::DirectUploadsController < Api::V2::BaseController
  include ActiveStorage::SetCurrent

  ALLOWED_CONTENT_TYPES = /\A(image\/(jpeg|jpg|png|gif)|video\/)/i

  before_action { doorkeeper_authorize! :edit_products }

  def create
    blob_args = direct_upload_blob_args
    return error_400("content_type must be JPEG, PNG, GIF, or video.") unless allowed_content_type?(blob_args[:content_type])

    blob = ActiveStorage::Blob.create_before_direct_upload!(**blob_args)

    render json: direct_upload_json(blob)
  rescue ActionController::ParameterMissing => e
    error_400(e.message)
  rescue ActiveRecord::RecordInvalid => e
    error_400(e.record.errors.full_messages.to_sentence)
  end

  private
    def direct_upload_blob_args
      params.require(:blob).permit(:filename, :byte_size, :checksum, :content_type, metadata: {}).to_h.symbolize_keys
    end

    def allowed_content_type?(content_type)
      content_type.present? && content_type.match?(ALLOWED_CONTENT_TYPES)
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
