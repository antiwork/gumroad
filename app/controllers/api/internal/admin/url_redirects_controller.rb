# frozen_string_literal: true

# Per-buyer delivery control. The disable-downloads switch belongs to the product file, so it
# applies to every buyer of that title; handing one buyer the download is a grant on that buyer's
# url redirect instead of a change to the seller's setting.
class Api::Internal::Admin::UrlRedirectsController < Api::Internal::Admin::BaseController
  # A grant changes what one buyer may do with a seller's file, so it needs an attributable
  # actor rather than the legacy shared token.
  before_action :require_per_actor_token!, only: %i[grant_download revoke_download]

  def show
    url_redirect = find_url_redirect
    return if url_redirect.nil?

    render json: { success: true, url_redirect: serialize_url_redirect(url_redirect) }
  end

  def grant_download
    url_redirect = find_url_redirect
    return if url_redirect.nil?
    return render_refused("Downloads can only be granted on a purchase's url redirect") if url_redirect.purchase.nil?
    return render_refused("Rental purchases cannot be granted downloads") if url_redirect.is_rental

    product_file = url_redirect.product_file(params[:product_file_id].to_s)
    return render_not_found("File not found") if product_file.nil?
    return render_refused("Downloads are already enabled for this file") unless product_file.stream_only?

    record_admin_write(action: "url_redirects.grant_download", target: url_redirect) do
      ProductFileDownloadGrant.find_or_create_by!(url_redirect:, product_file:)
      render json: { success: true, url_redirect: serialize_url_redirect(url_redirect.reload) }
    end
  end

  def revoke_download
    url_redirect = find_url_redirect
    return if url_redirect.nil?

    product_file = url_redirect.product_file(params[:product_file_id].to_s)
    return render_not_found("File not found") if product_file.nil?

    record_admin_write(action: "url_redirects.revoke_download", target: url_redirect) do
      ProductFileDownloadGrant.where(url_redirect_id: url_redirect.id, product_file_id: product_file.id).delete_all
      render json: { success: true, url_redirect: serialize_url_redirect(url_redirect.reload) }
    end
  end

  private
    # The token is what a buyer's link and a support thread carry; a redirect's own external id
    # appears nowhere a person can read it.
    def find_url_redirect
      url_redirect = UrlRedirect.find_by(token: params[:id])
      return url_redirect if url_redirect.present?

      render_not_found("Url redirect not found")
      nil
    end

    def serialize_url_redirect(url_redirect)
      purchase = url_redirect.purchase
      product = url_redirect.referenced_link
      {
        id: url_redirect.external_id,
        token: url_redirect.token,
        purchase_id: purchase&.external_id,
        buyer_email: purchase&.email,
        product_id: product&.external_id,
        product_name: product&.name,
        files: url_redirect.alive_product_files.map do |file|
          {
            id: file.external_id,
            name: file.name_displayable,
            downloads_disabled: file.stream_only?,
            download_granted: url_redirect.download_granted_for?(file),
            downloadable: url_redirect.is_file_downloadable?(file),
          }
        end
      }
    end

    def render_not_found(message)
      render json: { success: false, message: }, status: :not_found
    end

    def render_refused(message)
      render json: { success: false, message: }, status: :unprocessable_entity
    end
end
