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
    admin_api_token = token_to_manage
    return render_admin_token_not_found if admin_api_token.blank?

    record_admin_write(action: "auth.revoke", target: admin_api_token) do
      admin_api_token.revoke!
      render json: { success: true }
    end
  end

  def rotate
    admin_api_token = token_to_manage
    return render_admin_token_not_found if admin_api_token.blank?

    record_admin_write(action: "auth.rotate", target: admin_api_token) do
      if admin_api_token.expires_at.present?
        render json: { success: false, message: "only a token without an expiry can be rotated; revoke it instead" }, status: :unprocessable_entity
      elsif (rotated = admin_api_token.rotate!).blank?
        render_admin_token_not_found
      else
        plaintext_token, replacement = rotated
        render json: { success: true, token: plaintext_token, token_external_id: replacement.external_id }
      end
    end
  end

  private
    def render_invalid_authorization_code
      render json: { success: false, message: "authorization code is invalid" }, status: :unauthorized
    end

    def render_admin_token_not_found
      render json: { success: false, message: "admin token not found" }, status: :not_found
    end

    # Only admin tokens reach this controller. One may act on itself or on any service token (any
    # scope but admin) by external id, so a leaked agent token has a kill switch without a console
    # session; another actor's admin token stays out of reach.
    def token_to_manage
      external_id = params[:external_id].presence
      return Current.admin_token if external_id.blank?

      token = AdminApiToken.active.find_by(external_id:)
      return nil if token.blank?
      return token if token.actor_user_id == Current.admin_actor.id
      return nil if token.scope == AdminApiToken::ADMIN_SCOPE

      token
    end
end
