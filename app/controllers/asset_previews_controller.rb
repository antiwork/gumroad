# frozen_string_literal: true

class AssetPreviewsController < ApplicationController
  before_action :find_product
  after_action :verify_authorized

  def create
    authorize AssetPreview

    asset_preview = @product.asset_previews.build

    if permitted_params[:signed_blob_id].present?
      asset_preview.file.attach(permitted_params[:signed_blob_id])
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
    authorize asset_preview

    if asset_preview&.mark_deleted!
      render(json: { success: true, asset_previews: @product.display_asset_previews, active_preview_id: @product.main_preview && @product.main_preview.guid })
    else
      render(json: { success: false })
    end
  end

  private
    def find_product
      e404 unless user_signed_in?
      @product = Link.fetch(params[:link_id], user: current_seller) || e404
    end

    def permitted_params
      params.require(:asset_preview).permit(:signed_blob_id, :url)
    end
end
