# frozen_string_literal: true

class User::InvalidateActiveSessionsController < Sellers::BaseController
  def update
    user = current_seller
    authorize [:settings, :main, user], :invalidate_active_sessions?

    user.invalidate_active_sessions!

    sign_out

    flash[:notice] = "You have been signed out from all your active sessions. Please login again."
    flash[:notice_style] = "success"

    render json: { success: true }
  end
end
