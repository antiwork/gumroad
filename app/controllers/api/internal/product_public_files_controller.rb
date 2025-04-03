# frozen_string_literal: true

class Api::Internal::ProductPublicFilesController < Api::Internal::BaseController
  include FetchProductByUniquePermalink

  before_action :authenticate_user!
  before_action :fetch_product_and_enforce_ownership, only: :create
  after_action :verify_authorized

  def create
    authorize Link

    public_file = @product.public_files.build
    public_file.seller = current_seller
    public_file.file.attach(params[:signed_blob_id])
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
