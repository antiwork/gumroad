# frozen_string_literal: true

class Api::Internal::Admin::WhoamiController < Api::Internal::Admin::BaseController
  def show
    render json: {
      actor: serialize_whoami_actor,
      token: serialize_admin_token(Current.admin_token),
      scopes: ["admin"]
    }
  end

  private
    def serialize_whoami_actor
      return { external_id: nil, name: "Legacy internal admin token", email: nil } if Current.admin_token.legacy_admin_token?

      serialize_admin_actor(Current.admin_actor)
    end
end
