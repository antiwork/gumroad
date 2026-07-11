# frozen_string_literal: true

# Public v2 endpoint for a creator's public media library: image files hosted on
# Gumroad's public storage so they can be displayed on the creator's public pages. The profile and
# product custom-HTML landing pages render under a strict CSP that only allows img/media from
# Gumroad's own CDN hosts (RendersCustomHtmlPages::CUSTOM_HTML_CSP), so an off-platform file URL
# renders broken there — this endpoint is how a file becomes displayable: upload it here, then
# embed the returned `url` in the page HTML.
#
# This is also the store agent's image/media ingestion path (upload_media / list_media /
# delete_media in Ai::StoreAgentApiCatalog). The agent can't do a multipart upload from a chat tool
# call, so `create` accepts a remote `url` the server downloads itself — SSRF-guarded, magic-byte
# type-checked, size-capped, and content-moderated in CreatePublicMediaService.
#
# Files are scoped to the creator (PublicFile with resource = the seller), distinct from the
# per-product public files the product editor manages.
class Api::V2::MediaController < Api::V2::BaseController
  before_action(only: [:index]) { doorkeeper_authorize! :view_profile }
  before_action(only: [:index]) { require_oauth_scope! :view_profile }
  before_action(only: [:create, :destroy]) { doorkeeper_authorize! :edit_profile }
  before_action(only: [:create, :destroy]) { require_oauth_scope! :edit_profile }
  # Suspended or closed accounts must not be able to keep hosting files on Gumroad's public
  # storage. The app-wide suspended-account guard only covers browser sessions (logged_in_user),
  # not OAuth bearer tokens, so without this check a suspended seller's still-valid API token
  # could continue using this endpoint as a free public file host. `destroy` is deliberately NOT
  # guarded: deleting hosted media is remediation (it reduces what the account hosts), so a
  # suspended seller should still be able to take their files down.
  before_action(only: [:create]) { render_account_inactive unless current_resource_owner&.account_active? }

  def index
    files = media_files.order(id: :desc).with_attached_file
    render_response(true, media: files.map { |file| media_json(file) })
  end

  def create
    result = CreatePublicMediaService.new(
      seller: current_resource_owner,
      url: params[:url],
      signed_blob_id: params[:signed_blob_id],
      name: params[:name],
    ).process

    if result.success?
      render_response(true, media: media_json(result.public_file))
    else
      render_response(false, message: result.error_message)
    end
  end

  def destroy
    file = media_files.find_by(public_id: params[:id])
    return error_with_object(:media, nil) if file.nil?

    # The creator asked for this file to be gone, so delete now rather than reusing the delayed
    # "unused file" cleanup. Any page still embedding the URL will show it broken — which is the
    # honest outcome of deleting a file that's still referenced.
    file.mark_deleted_and_purge_file!
    render_response(true, message: "The file was deleted.")
  end

  private
    def media_files
      PublicFile.alive.where(seller: current_resource_owner, resource: current_resource_owner)
    end

    # 403 with the standard v2 `{ success: false, message: ... }` body. Rendering from a
    # before_action halts the request, so the action never runs for inactive accounts.
    def render_account_inactive
      render json: { success: false, message: "Your account is not active." }, status: :forbidden
    end

    def media_json(public_file)
      PublicFilePresenter.new(public_file:).props.merge(
        file_group: public_file.file_group,
        created_at: public_file.created_at,
      )
    end
end
