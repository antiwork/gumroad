# frozen_string_literal: true

class Api::Internal::Admin::UsersController < Api::Internal::Admin::BaseController
  def suspension
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = User.alive.by_email(params[:email]).first
    return render json: { success: false, message: "User not found" }, status: :not_found if user.blank?

    last_status_comment = user.comments
      .where(comment_type: [Comment::COMMENT_TYPE_SUSPENSION_NOTE, Comment::COMMENT_TYPE_SUSPENDED, Comment::COMMENT_TYPE_FLAGGED, Comment::COMMENT_TYPE_COMPLIANT])
      .order(created_at: :desc)
      .first

    render json: {
      success: true,
      status: suspension_status(user),
      updated_at: last_status_comment&.created_at&.as_json,
      appeal_url: nil
    }
  end

  private
    def suspension_status(user)
      if user.suspended?
        "Suspended"
      elsif user.flagged?
        "Flagged"
      else
        "Compliant"
      end
    end
end
