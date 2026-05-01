# frozen_string_literal: true

class Api::Internal::Admin::AuthController < Api::Internal::Admin::BaseController
  skip_before_action :verify_authorization_header!, only: :exchange
  skip_before_action :authorize_admin_token!, only: :exchange

  def exchange
    result = AdminApiAuthorizationCode.exchange!(code: params[:code], code_verifier: params[:code_verifier])
    return render_invalid_authorization_code if result.blank?

    plaintext_token, admin_api_token = result

    render json: {
      token: plaintext_token,
      token_external_id: admin_api_token.external_id,
      expires_at: admin_api_token.expires_at.as_json,
      actor: serialize_admin_actor(admin_api_token.actor_user)
    }
  end

  def revoke
    admin_api_token = token_to_revoke
    return render json: { success: false, message: "admin token not found" }, status: :not_found if admin_api_token.blank?

    record_admin_write(action: "auth.revoke", target: admin_api_token) do
      admin_api_token.update!(revoked_at: Time.current)
      render json: { success: true }
    end
  end

  private
    def render_invalid_authorization_code
      render json: { success: false, message: "authorization code is invalid" }, status: :unauthorized
    end

    def token_to_revoke
      external_id = params[:external_id].presence
      return Current.admin_token if external_id.blank?

      AdminApiToken.active.find_by(external_id:, actor_user_id: Current.admin_actor.id)
    end
end
