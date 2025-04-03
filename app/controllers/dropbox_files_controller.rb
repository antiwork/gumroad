# frozen_string_literal: true

class DropboxFilesController < Sellers::BaseController
  before_action :authorize

  def create
    dropbox_file = DropboxFile.create_with_file_info(permitted_params)
    dropbox_file.user = current_seller
    if permitted_params[:link_id]
      fetch_product_and_enforce_ownership
      dropbox_file.link = @product
    end
    dropbox_file.save!
    render json: { dropbox_file: }
  end

  def index
    fetch_product_and_enforce_ownership if permitted_params[:link_id]
    dropbox_files = @product.present? ? @product.dropbox_files.available_for_product : current_seller.dropbox_files.available
    render json: { dropbox_files: }
  end

  def cancel_upload
    dropbox_file = current_seller.dropbox_files.find_by_external_id(permitted_params[:id])
    return render json: { success: false } if dropbox_file.nil?

    if dropbox_file.successfully_uploaded?
      dropbox_file.mark_deleted!
    elsif dropbox_file.in_progress?
      dropbox_file.mark_cancelled!
    end
    render json: { dropbox_file:, success: true }
  end

  private
    def permitted_params
      params.permit(:id, :bytes, :name, :link, :icon, :link_id)
    end

    def authorize
      super(:dropbox_files)
    end
end
