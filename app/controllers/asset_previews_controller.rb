# frozen_string_literal: true

class AssetPreviewsController < ApplicationController
  before_action :find_product
  after_action :verify_authorized

  def create
    authorize AssetPreview

    return render(json: { success: false, error: "Could not process your preview, please try again." }) unless params[:asset_preview].is_a?(ActionController::Parameters)

    asset_preview = @product.asset_previews.build

    if permitted_params[:signed_blob_id].present?
      signed_blob_id = permitted_params[:signed_blob_id]
      # attach() resolves the raw string with ActiveStorage::Blob.find_signed!, which raises
      # InvalidSignature for a tampered or expired id — resolve here so the request is a 400 and
      # the verified blob is what gets attached.
      blob = signed_blob_id.is_a?(String) ? ActiveStorage::Blob.find_signed(signed_blob_id) : nil
      unless blob
        return render(json: { success: false, error: "Invalid signed_blob_id." }, status: :bad_request)
      end

      asset_preview.file.attach(blob)
    else
      asset_preview.url = permitted_params[:url]
    end

    asset_preview.analyze_file

    if asset_preview.save
      render(json: { success: true, asset_previews: @product.display_asset_previews, active_preview_id: asset_preview.guid })
    else
      asset_preview.file&.blob&.purge
      render(json: { success: false, error: asset_preview.errors.any? ? asset_preview.errors.full_messages.to_sentence : "Could not process your preview, please try again." })
    end
  rescue *INTERNET_EXCEPTIONS
    render(json: { success: false, error: "Could not process your preview, please try again." })
  end

  def destroy
    asset_preview = @product.asset_previews.where(guid: params[:id]).first
    # A stale editor can DELETE a preview that is not in this product; authorizing nil
    # raises Pundit::NotDefinedError, so "nothing to delete" is a plain failed delete.
    unless asset_preview
      skip_authorization
      return render(json: { success: false })
    end

    authorize asset_preview

    if asset_preview.mark_deleted!
      render(json: { success: true, asset_previews: @product.display_asset_previews, active_preview_id: @product.main_preview && @product.main_preview.guid })
    else
      render(json: { success: false })
    end
  end

  private
    def find_product
      e404 unless user_signed_in?
      fetch_product_and_enforce_access
    end

    def permitted_params
      params.require(:asset_preview).permit(:signed_blob_id, :url)
    end
end
