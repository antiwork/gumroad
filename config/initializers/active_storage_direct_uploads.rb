# frozen_string_literal: true

# ActiveStorage::DirectUploadsController hands the permitted blob params straight to
# Blob.create_before_direct_upload!, whose required keywords raise ArgumentError when a key is
# absent — so a reservation without `checksum` answered 500. A malformed body is a client error;
# answer 400 like Api::V2::DirectUploadsController does.
module ActiveStorageDirectUploadsBadRequest
  REQUIRED_BLOB_KEYS = [:filename, :byte_size, :checksum].freeze

  def create
    blob = params[:blob]
    unless blob.is_a?(ActionController::Parameters) && REQUIRED_BLOB_KEYS.all? { |key| blob[key].present? }
      return render json: { error: "blob must include filename, byte_size and checksum" }, status: :bad_request
    end

    super
  end
end

Rails.application.config.to_prepare do
  ActiveStorage::DirectUploadsController.prepend(ActiveStorageDirectUploadsBadRequest)
end
