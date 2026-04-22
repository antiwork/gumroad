# frozen_string_literal: true

class Api::V2::CoversController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_products }
  before_action :fetch_product

  def create
    asset_preview = @product.asset_previews.build

    if params[:signed_blob_id].present?
      asset_preview.file.attach(params[:signed_blob_id])
    elsif params[:url].present?
      asset_preview.url = params[:url]
    else
      return render_response(false, message: "Please provide a signed_blob_id or url.")
    end

    asset_preview.analyze_file

    if asset_preview.save
      success_with_covers
    else
      asset_preview.file&.blob&.purge
      error_with_creating_object(:cover, asset_preview)
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    render_response(false, message: "The signed_blob_id is invalid or expired.")
  rescue ActiveRecord::InvalidForeignKey, ActiveStorage::FileNotFoundError, *INTERNET_EXCEPTIONS
    render_response(false, message: "Could not process your cover, please try again.")
  end

  def destroy
    asset_preview = @product.asset_previews.alive.find_by(guid: params[:id])

    if asset_preview&.mark_deleted!
      success_with_covers
    else
      render_response(false, message: "The cover was not found.")
    end
  end

  private
    def success_with_covers
      covers = @product.display_asset_previews.reload
      render_response(true, covers: covers, main_cover_id: covers.first&.guid)
    end
end
