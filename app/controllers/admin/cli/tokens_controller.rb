# frozen_string_literal: true

class Admin::Cli::TokensController < Admin::BaseController
  def index
    set_meta_tag(title: "CLI tokens")

    render inertia: "Admin/Cli/Tokens/Index", props: {
      tokens: admin_cli_tokens.map { serialize_token(_1) }
    }
  end

  def revoke
    admin_api_token = admin_cli_tokens.find_by(external_id: params[:external_id])
    if admin_api_token.present?
      admin_api_token.update!(revoked_at: Time.current)
      redirect_to admin_cli_tokens_path, status: :see_other, notice: "CLI token revoked."
    else
      redirect_to admin_cli_tokens_path, status: :see_other, alert: "CLI token not found."
    end
  end

  private
    def admin_cli_tokens
      AdminApiToken.active.where(actor_user: current_user).where.not(expires_at: nil).order(created_at: :desc)
    end

    def serialize_token(admin_api_token)
      {
        external_id: admin_api_token.external_id,
        created_at: admin_api_token.created_at.as_json,
        last_used_at: admin_api_token.last_used_at&.as_json,
        expires_at: admin_api_token.expires_at&.as_json,
        revoke_path: revoke_admin_cli_token_path(admin_api_token.external_id)
      }
    end
end
