# frozen_string_literal: true

class Api::Mobile::DirectUploadsController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }
  before_action :authorize_creator!

  def create
    blob = ActiveStorage::Blob.create_before_direct_upload!(**blob_args)
    render json: direct_upload_json(blob)
  end

  private
    def pundit_user
      @_pundit_user ||= SellerContext.new(user: current_api_user, seller: current_api_user)
    end

    def authorize_creator!
      authorize Installment, :create?
    rescue Pundit::NotAuthorizedError
      render json: { success: false, message: "This account can't upload files." }, status: :forbidden
    end

    def blob_args
      params.require(:blob).permit(:filename, :byte_size, :checksum, :content_type, metadata: {}).to_h.symbolize_keys
    end

    def direct_upload_json(blob)
      {
        signed_id: blob.signed_id,
        key: blob.key,
        filename: blob.filename.to_s,
        content_type: blob.content_type,
        byte_size: blob.byte_size,
        direct_upload: {
          url: blob.service_url_for_direct_upload,
          headers: blob.service_headers_for_direct_upload
        }
      }
    end
end
