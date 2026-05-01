# frozen_string_literal: true

class Admin::Cli::TokensController < Admin::BaseController
  def index
    set_meta_tag(title: "Admin API tokens")

    render inertia: "Admin/Cli/Tokens/Index", props: {
      tokens: admin_api_tokens.map { serialize_token(_1) }
    }
  end

  def revoke
    admin_api_token = AdminApiToken.active.find_by(external_id: params[:external_id])
    if admin_api_token.present?
      admin_api_token.update!(revoked_at: Time.current)
      redirect_to admin_cli_tokens_path, status: :see_other, notice: "Admin API token revoked."
    else
      redirect_to admin_cli_tokens_path, status: :see_other, alert: "Active admin API token not found."
    end
  end

  private
    def admin_api_tokens
      AdminApiToken.active.includes(:actor_user).order(created_at: :desc, id: :desc)
    end

    def serialize_token(admin_api_token)
      {
        external_id: admin_api_token.external_id,
        actor: serialize_actor(admin_api_token),
        kind: token_kind(admin_api_token),
        created_at: admin_api_token.created_at.as_json,
        last_used_at: admin_api_token.last_used_at&.as_json,
        expires_at: admin_api_token.expires_at&.as_json,
        revoke_path: revoke_admin_cli_token_path(admin_api_token.external_id)
      }
    end

    def serialize_actor(admin_api_token)
      return { id: nil, name: "Legacy internal admin token", email: nil } if admin_api_token.legacy_admin_token?

      actor_user = admin_api_token.actor_user
      return { id: nil, name: nil, email: nil } if actor_user.blank?

      {
        id: actor_user.id,
        name: actor_user.name,
        email: actor_user.email
      }
    end

    def token_kind(admin_api_token)
      return "Legacy" if admin_api_token.legacy_admin_token?
      return "CLI" if admin_api_token.expires_at.present?

      "Service"
    end
end
