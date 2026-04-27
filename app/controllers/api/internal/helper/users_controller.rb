# frozen_string_literal: true

class Api::Internal::Helper::UsersController < Api::Internal::Helper::BaseController
  skip_before_action :authorize_helper_token!, only: [:user_info]
  before_action :authorize_hmac_signature!, only: [:user_info]

  def user_info
    render json: { success: false, error: "'email' parameter is required" }, status: :bad_request if params[:email].blank?

    render json: {
      success: true,
      customer: HelperUserInfoService.new(email: params[:email]).customer_info,
    }
  end

  def user_suspension_info
    if params[:email].blank?
      render json: { success: false, error: "'email' parameter is required" }, status: :bad_request
      return
    end

    user = User.alive.by_email(params[:email]).first
    if user.blank?
      return render json: { success: false, error_message: "An account does not exist with that email." }, status: :unprocessable_entity
    end

    status = if user.suspended?
      "Suspended"
    elsif user.flagged?
      "Flagged"
    else
      "Compliant"
    end

    last_status_comment = user.comments
      .where(comment_type: [Comment::COMMENT_TYPE_SUSPENSION_NOTE, Comment::COMMENT_TYPE_SUSPENDED, Comment::COMMENT_TYPE_FLAGGED, Comment::COMMENT_TYPE_COMPLIANT])
      .order(created_at: :desc)
      .first

    render json: {
      success: true,
      status: status,
      updated_at: last_status_comment&.created_at,
      appeal_url: nil
    }
  end

  def send_reset_password_instructions
    if EmailFormatValidator.valid?(params[:email])
      user = User.alive.by_email(params[:email]).first
      if user
        user.send_reset_password_instructions
        render json: { success: true, message: "Reset password instructions sent" }
      else
        render json: { error_message: "An account does not exist with that email." },
               status: :unprocessable_entity
      end
    else
      render json: { error_message: "Invalid email" }, status: :unprocessable_entity
    end
  end

  def update_email
    if params[:current_email].blank? || params[:new_email].blank?
      render json: { error_message: "Both current and new email are required." }, status: :unprocessable_entity
      return
    end

    if !EmailFormatValidator.valid?(params[:new_email])
      render json: { error_message: "Invalid new email format." }, status: :unprocessable_entity
      return
    end

    user = User.alive.by_email(params[:current_email]).first
    if user
      user.email = params[:new_email]
      if user.save
        render json: { message: "Email updated." }
      else
        render json: { error_message: user.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    else
      render json: { error_message: "An account does not exist with that email." }, status: :unprocessable_entity
    end
  end

  def update_two_factor_authentication_enabled
    if params[:email].blank?
      return render json: { success: false, error_message: "Email is required." }, status: :unprocessable_entity
    end

    if params[:enabled].nil?
      return render json: { success: false, error_message: "Enabled status is required." }, status: :unprocessable_entity
    end

    user = User.alive.by_email(params[:email]).first
    if user.present?
      user.two_factor_authentication_enabled = params[:enabled]
      if user.save
        user.totp_credential&.destroy unless user.two_factor_authentication_enabled?
        render json: { success: true, message: "Two-factor authentication #{user.two_factor_authentication_enabled? ? "enabled" : "disabled"}." }
      else
        render json: { success: false, error_message: user.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    else
      render json: { success: false, error_message: "An account does not exist with that email." }, status: :unprocessable_entity
    end
  end

  def create_comment
    if params[:email].blank?
      return render json: { success: false, error_message: "'email' parameter is required" }, status: :bad_request
    end
    if params[:content].blank?
      return render json: { success: false, error_message: "'content' parameter is required" }, status: :bad_request
    end
    if params[:idempotency_key].blank?
      return render json: { success: false, error_message: "'idempotency_key' parameter is required" }, status: :bad_request
    end

    user = User.alive.by_email(params[:email]).first
    if user.blank?
      return render json: { success: false, error_message: "An account does not exist with that email." }, status: :unprocessable_entity
    end

    normalized_content = Comment.normalize_content(params[:content])

    existing = user.comments.find_by(idempotency_key: params[:idempotency_key])
    if existing
      if existing.content != normalized_content
        return render json: { success: false, error_message: "Idempotency key already used with different content" }, status: :conflict
      end
      return render json: { success: true, comment: HelperUserInfoService.serialize_comment(existing) }
    end

    comment = user.comments.new(
      content: params[:content],
      comment_type: Comment::COMMENT_TYPE_NOTE,
      author_id: GUMROAD_ADMIN_ID,
      idempotency_key: params[:idempotency_key]
    )

    if comment.save
      render json: { success: true, comment: HelperUserInfoService.serialize_comment(comment) }
    else
      render json: { success: false, error_message: comment.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    existing = user.comments.find_by!(idempotency_key: params[:idempotency_key])
    if existing.content != normalized_content
      render json: { success: false, error_message: "Idempotency key already used with different content" }, status: :conflict
    else
      render json: { success: true, comment: HelperUserInfoService.serialize_comment(existing) }
    end
  end

  def create_appeal
    if params[:email].blank?
      return render json: { success: false, error_message: "'email' parameter is required" }, status: :bad_request
    end

    if params[:reason].blank?
      return render json: { success: false, error_message: "'reason' parameter is required" }, status: :bad_request
    end

    user = User.alive.by_email(params[:email]).first
    if user.blank?
      return render json: { success: false, error_message: "An account does not exist with that email." }, status: :unprocessable_entity
    end

    if !user.suspended? && !user.flagged?
      return render json: { success: false, error_message: "User is not suspended or flagged" }, status: :unprocessable_entity
    end

    comment = user.comments.new(
      content: "Appeal submitted: #{params[:reason]}",
      author_name: ContentModeration::ModerateRecordService::AUTHOR_NAME,
      comment_type: Comment::COMMENT_TYPE_NOTE
    )

    unless comment.save
      return render json: { success: false, error_message: comment.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end

    render json: {
      success: true,
      id: comment.id,
      appeal_url: nil
    }
  end
end
