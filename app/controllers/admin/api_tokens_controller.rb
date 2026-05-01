# frozen_string_literal: true

class Admin::ApiTokensController < Admin::BaseController
  def index
    set_meta_tag(title: "Admin API tokens")

    legacy_admin_token_id = AdminApiToken.legacy_admin_token&.id
    render inertia: "Admin/ApiTokens/Index", props: {
      tokens: admin_api_tokens.map { serialize_token(_1, legacy: _1.id == legacy_admin_token_id) }
    }
  end

  def revoke
    admin_api_token = AdminApiToken.active.find_by(external_id: params[:external_id])
    if admin_api_token.present?
      admin_api_token.update!(revoked_at: Time.current)
      redirect_to admin_api_tokens_path, status: :see_other, notice: "Admin API token revoked."
    else
      redirect_to admin_api_tokens_path, status: :see_other, alert: "Active admin API token not found."
    end
  end

  private
    def admin_api_tokens
      AdminApiToken.active.includes(:actor_user).order(created_at: :desc, id: :desc)
    end

    def serialize_token(admin_api_token, legacy:)
      {
        external_id: admin_api_token.external_id,
        actor: serialize_actor(admin_api_token, legacy:),
        kind: token_kind(admin_api_token, legacy:),
        created_at: admin_api_token.created_at.as_json,
        last_used_at: admin_api_token.last_used_at&.as_json,
        expires_at: admin_api_token.expires_at&.as_json,
        revoke_path: revoke_admin_api_token_path(admin_api_token.external_id)
      }
    end

    def serialize_actor(admin_api_token, legacy:)
      return { id: nil, name: "Legacy internal admin token", email: nil } if legacy

      actor_user = admin_api_token.actor_user
      return { id: nil, name: nil, email: nil } if actor_user.blank?

      {
        id: actor_user.id,
        name: actor_user.name,
        email: actor_user.email
      }
    end

    def token_kind(admin_api_token, legacy:)
      return "Legacy" if legacy
      return "CLI" if admin_api_token.expires_at.present?

      "Service"
    end
end
