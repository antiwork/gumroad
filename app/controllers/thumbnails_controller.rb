# frozen_string_literal: true

class ThumbnailsController < Sellers::BaseController
  before_action :find_product

  def create
    authorize Thumbnail

    thumbnail = @product.thumbnail || @product.build_thumbnail

    if permitted_params[:signed_blob_id].present?
      thumbnail.file.attach(permitted_params[:signed_blob_id])
      thumbnail.file.analyze
      thumbnail.unsplash_url = nil
    end

    # Mark alive if previously deleted
    thumbnail.deleted_at = nil

    if thumbnail.save
      render(json: { success: true, thumbnail: @product.thumbnail })
    else
      render(json: { success: false, error: thumbnail.errors.any? ? thumbnail.errors.full_messages.to_sentence : "Could not process your preview, please try again." })
    end
  rescue *INTERNET_EXCEPTIONS
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
