# frozen_string_literal: true

class Api::V2::ThumbnailsController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_products }
  before_action :fetch_product

  def create
    thumbnail = @product.thumbnail || @product.build_thumbnail
    thumbnail.unsplash_url = nil
    thumbnail.deleted_at = nil

    if params[:signed_blob_id].present?
      thumbnail.file.attach(params[:signed_blob_id])
    elsif params[:url].present?
      thumbnail.url = params[:url]
    else
      return render_response(false, message: "Please provide a signed_blob_id or url.")
    end

    thumbnail.file.analyze if thumbnail.file.attached? && !thumbnail.file.analyzed?

    if thumbnail.save
      render_response(true, thumbnail: thumbnail)
    else
      thumbnail.file&.blob&.purge
      error_with_creating_object(:thumbnail, thumbnail)
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    render_response(false, message: "The signed_blob_id is invalid or expired.")
  rescue URI::InvalidURIError, Addressable::URI::InvalidURIError, SsrfFilter::CRLFInjection, SsrfFilter::InvalidUriScheme, SsrfFilter::PrivateIPAddress, SsrfFilter::TooManyRedirects, SsrfFilter::UnresolvedHostname
    render status: :bad_request, json: { success: false, message: "Please provide a valid public image URL." }
  rescue Thumbnail::RemoteFileTooLarge
    render_response(false, message: "Could not process your thumbnail, please upload an image with size smaller than 5 MB.")
  rescue ActiveRecord::InvalidForeignKey, ActiveStorage::FileNotFoundError, *INTERNET_EXCEPTIONS
    render_response(false, message: "Could not process your thumbnail, please try again.")
  end

  def destroy
    thumbnail = @product.thumbnail
    if thumbnail&.alive? && thumbnail.mark_deleted!
      render_response(true, thumbnail: nil)
    else
      render_response(false, message: "The thumbnail was not found.")
    end
  end
end
