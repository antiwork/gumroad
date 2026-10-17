# frozen_string_literal: true

class Api::Internal::ProductPublicFilesController < Api::Internal::BaseController
  include FetchProductByUniquePermalink

  before_action :authenticate_user!
  before_action :fetch_product_and_enforce_ownership, only: :create
  after_action :verify_authorized

  def create
    authorize Link

    signed_blob_id = params[:signed_blob_id]
    # attach() resolves the raw string with ActiveStorage::Blob.find_signed!, which raises
    # InvalidSignature for a tampered or expired id — resolve here so the request is a 400 and
    # the verified blob is what gets attached.
    blob = signed_blob_id.is_a?(String) ? ActiveStorage::Blob.find_signed(signed_blob_id) : nil
    unless blob
      return render(json: { success: false, error: "Invalid signed_blob_id." }, status: :bad_request)
    end

    public_file = @product.public_files.build
    public_file.seller = current_seller
    public_file.file.attach(blob)
    if public_file.save
      render json: { success: true, id: public_file.public_id }
    else
      render json: { success: false, error: public_file.errors.full_messages.first }
    end
  end

  private
    def fetch_product_and_enforce_ownership
      @product = Link.find_by_external_id(params[:product_id])
      e404 if @product.nil?
      e404 if @product.user != current_seller
    end
end
