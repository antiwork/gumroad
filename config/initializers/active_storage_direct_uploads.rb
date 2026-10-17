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

Rails.application.config.to_prepare do
  ActiveStorage::DirectUploadsController.prepend(ActiveStorageDirectUploadsBadRequest)
end
