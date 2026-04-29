# frozen_string_literal: true

class Api::Internal::Admin::UsersController < Api::Internal::Admin::BaseController
  def suspension
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = find_user_or_render(params[:email])
    return unless user

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

  def reset_password
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?
    return render json: { success: false, message: "Invalid email format" }, status: :bad_request unless EmailFormatValidator.valid?(params[:email])

    user = find_user_or_render(params[:email])
    return unless user

    user.send_reset_password_instructions
    render json: { success: true, message: "Reset password instructions sent" }
  end

  def update_email
    if params[:current_email].blank? || params[:new_email].blank?
      return render json: { success: false, message: "Both current_email and new_email are required" }, status: :bad_request
    end

    unless EmailFormatValidator.valid?(params[:new_email])
      return render json: { success: false, message: "Invalid new email format" }, status: :bad_request
    end

    user = find_user_or_render(params[:current_email])
    return unless user

    if user.email.to_s.casecmp(params[:new_email].to_s).zero?
      return render json: { success: false, message: "New email is the same as the current email" }, status: :unprocessable_entity
    end

    user.email = params[:new_email]
    unless user.save
      return render json: { success: false, message: user.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end

    if user.unconfirmed_email.present?
      render json: {
        success: true,
        message: "Email change pending confirmation. Confirmation email sent to #{user.unconfirmed_email}.",
        unconfirmed_email: user.unconfirmed_email,
        pending_confirmation: true
      }
    else
      render json: {
        success: true,
        message: "Email updated.",
        email: user.email,
        pending_confirmation: false
      }
    end
  end

  def two_factor_authentication
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?
    return render json: { success: false, message: "enabled is required" }, status: :bad_request if params[:enabled].to_s.blank?

    user = find_user_or_render(params[:email])
    return unless user

    enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
    user.two_factor_authentication_enabled = enabled

    if user.save
      user.totp_credential&.destroy unless user.two_factor_authentication_enabled?
      render json: {
        success: true,
        message: "Two-factor authentication #{enabled ? "enabled" : "disabled"}",
        two_factor_authentication_enabled: user.two_factor_authentication_enabled?
      }
    else
      render json: { success: false, message: user.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  def create_comment
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?
    return render json: { success: false, message: "content is required" }, status: :bad_request if params[:content].blank?
    return render json: { success: false, message: "idempotency_key is required" }, status: :bad_request if params[:idempotency_key].blank?

    user = find_user_or_render(params[:email])
    return unless user

    comment = User::CreateAdminCommentService.new(user:, content: params[:content], idempotency_key: params[:idempotency_key]).perform

    if comment.persisted?
      render json: { success: true, comment: serialize_comment(comment) }
    else
      render json: { success: false, message: comment.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  rescue User::CreateAdminCommentService::IdempotencyConflictError
    render json: { success: false, message: "Idempotency key already used with different content" }, status: :conflict
  end

  def mark_compliant
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = find_user_or_render(params[:email])
    return unless user

    if user.compliant?
      return render json: { success: true, status: "already_compliant", message: "User is already compliant" }
    end

    note = build_admin_note(user, params[:note]) if params[:note].present?
    return render_invalid_comment(note) if note&.invalid?

    user.mark_compliant!(author_id: GUMROAD_ADMIN_ID)
    note&.save!
    render json: { success: true, status: "marked_compliant", message: "User marked compliant" }
  rescue StateMachines::InvalidTransition => e
    render json: { success: false, message: e.message }, status: :unprocessable_entity
  end

  def suspend_for_fraud
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = find_user_or_render(params[:email])
    return unless user

    if user.suspended_for_fraud?
      return render json: { success: true, status: "already_suspended", message: "User is already suspended for fraud" }
    end

    suspension_note = build_suspension_note(user) if params[:suspension_note].present?
    return render_invalid_comment(suspension_note) if suspension_note&.invalid?

    user.suspend_for_fraud!(author_id: GUMROAD_ADMIN_ID)
    suspension_note&.save!
    render json: { success: true, status: "suspended_for_fraud", message: "User suspended for fraud" }
  rescue StateMachines::InvalidTransition => e
    render json: { success: false, message: e.message }, status: :unprocessable_entity
  end

  private
    def find_user_or_render(email)
      user = User.alive.by_email(email).first
      return user if user.present?

      render json: { success: false, message: "User not found" }, status: :not_found
      nil
    end

    def suspension_status(user)
      if user.suspended?
        "Suspended"
      elsif user.flagged?
        "Flagged"
      else
        "Compliant"
      end
    end

    def serialize_comment(comment)
      {
        id: comment.external_id,
        author_name: comment.author_name.presence || comment.author&.name || "System",
        content: comment.content,
        comment_type: comment.comment_type,
        created_at: comment.created_at.iso8601
      }
    end

    def build_admin_note(user, content)
      user.comments.new(
        author_id: GUMROAD_ADMIN_ID,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content:
      )
    end

    def build_suspension_note(user)
      user.comments.new(
        author_id: GUMROAD_ADMIN_ID,
        comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
        content: params[:suspension_note]
      )
    end

    def render_invalid_comment(comment)
      render json: { success: false, message: comment.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
end
