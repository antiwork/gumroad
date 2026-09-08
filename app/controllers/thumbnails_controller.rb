# frozen_string_literal: true

class ThumbnailsController < Sellers::BaseController
  before_action :find_product

  def create
    authorize Thumbnail

    if !params[:thumbnail].respond_to?(:permit)
      return render(json: { success: false, error: "Invalid thumbnail parameter. Expected signed_blob_id." }, status: :bad_request)
    end

    thumbnail = @product.thumbnail || @product.build_thumbnail

    signed_blob_id = permitted_params[:signed_blob_id]
    if signed_blob_id.present?
      unless signed_blob_id.is_a?(String) && (blob = ActiveStorage::Blob.find_signed(signed_blob_id))
        return render(json: { success: false, error: "Invalid signed_blob_id." }, status: :bad_request)
      end

      thumbnail.file.attach(blob)
      Timeout.timeout(30) { thumbnail.file.analyze }
      thumbnail.unsplash_url = nil
    end

    # Mark alive if previously deleted
    thumbnail.deleted_at = nil

    if thumbnail.save
      render(json: { success: true, thumbnail: @product.thumbnail })
    else
      render(json: { success: false, error: thumbnail.errors.any? ? thumbnail.errors.full_messages.to_sentence : "Could not process your preview, please try again." })
    end
  rescue Timeout::Error
    render(json: { success: false, error: "Thumbnail processing took too long, please try again with a smaller image." })
  rescue ActiveRecord::InvalidForeignKey, ActiveStorage::FileNotFoundError, *INTERNET_EXCEPTIONS
    render(json: { success: false, error: "Could not process your thumbnail, please try again." })
  end

  def destroy
    authorize Thumbnail

    thumbnail = @product.thumbnail&.guid == params[:id] ? @product.thumbnail : nil
    if thumbnail&.mark_deleted!
      render(json: { success: true, thumbnail: @product.thumbnail })
    else
      render(json: { success: false })
    end
  end

  private
    def find_product
      @product = Link.fetch(params[:link_id], user: current_seller) || e404
    end

    def permitted_params
      params.require(:thumbnail).permit(:signed_blob_id)
    end
end
