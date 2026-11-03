# frozen_string_literal: true

# A seller links their Gumroad account to their account on a partner application by authorizing that
# application (an authorization code grant with the partner_api scope). The partner then calls this
# endpoint with the seller's token. Linking imports nothing: the listing endpoints include the seller's
# published products, and an export still needs the seller to confirm it on the onboarding link.
class Api::V2::Partner::SellersController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :partner_api }
  before_action { require_oauth_scope! :partner_api }
  before_action :require_seller_of_partner_application!

  def create
    external_user_id = params[:external_user_id]
    max_length = PartnerMigration::MAX_EXTERNAL_USER_ID_LENGTH
    unless external_user_id.is_a?(String) && external_user_id.present? && external_user_id.length <= max_length
      return render json: { success: false, message: "external_user_id must be a string with 1 to #{max_length} characters, not only spaces." }, status: :bad_request
    end
    unless current_resource_owner.account_active?
      return render json: { success: false, message: "This account cannot be linked." }, status: :forbidden
    end

    # The same lock as the claim, which links the seller too, and as revoke_access_for. A revocation
    # that committed while this request waited for the lock must win, so the token is read again.
    partner_seller = partner_application.with_lock do
      next unless doorkeeper_token.reload.accessible?

      PartnerSeller.link!(oauth_application: partner_application, user: current_resource_owner, external_user_id:)
    end
    return render json: { success: false, message: "The seller revoked access for this application." }, status: :unauthorized if partner_seller.nil?

    render json: { success: true, external_user_id: partner_seller.external_user_id }, status: partner_seller.previously_new_record? ? :created : :ok
  rescue PartnerSeller::LinkConflict => e
    render json: { success: false, message: e.message }, status: :conflict
  end

  private
    def partner_application
      @partner_application ||= OauthApplication.alive.find_by(id: doorkeeper_token.application_id)
    end

    # Only a seller's token counts: a client credentials token has no seller to link.
    def require_seller_of_partner_application!
      application = partner_application
      return if doorkeeper_token.resource_owner_id.present? && application&.is_partner? && application.confidential?

      render json: { success: false, message: "This endpoint needs a seller's token from a partner application." }, status: :forbidden
    end
end
