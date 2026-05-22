# frozen_string_literal: true

class Api::V2::DirectUploadsController < Api::V2::BaseController
  include ActiveStorage::SetCurrent

  before_action { doorkeeper_authorize! :edit_products }

  def create
    blob = ActiveStorage::Blob.create_before_direct_upload!(**blob_args)

    render json: direct_upload_json(blob)
  end

  private
    def blob_args
      params.require(:blob).permit(:filename, :byte_size, :checksum, :content_type, metadata: {}).to_h.symbolize_keys
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
