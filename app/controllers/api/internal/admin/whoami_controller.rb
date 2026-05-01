# frozen_string_literal: true

class Api::Internal::Admin::WhoamiController < Api::Internal::Admin::BaseController
  def show
    render json: {
      actor: serialize_admin_actor(Current.admin_actor),
      token: serialize_admin_token(Current.admin_token),
      scopes: ["admin"]
    }
  end
end
