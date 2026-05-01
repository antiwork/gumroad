# frozen_string_literal: true

class Api::Internal::Admin::UsersController < Api::Internal::Admin::BaseController
  def info
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = User.by_email(params[:email]).first
    return render json: { success: false, message: "User not found" }, status: :not_found if user.blank?

    render json: { success: true, user: serialize_user_info(user) }
  end

  def suspension
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = find_user_or_render(params[:email])
    return unless user

    render json: {
      success: true,
      status: suspension_status(user),
      updated_at: last_status_changed_at(user)&.as_json,
      appeal_url: nil
    }
  end

  def reset_password
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?
    return render json: { success: false, message: "Invalid email format" }, status: :bad_request unless EmailFormatValidator.valid?(params[:email])

    user = find_user_or_render(params[:email])
    return unless user

    record_admin_write(action: "users.reset_password", target: user) do
      user.send_reset_password_instructions
      render json: { success: true, message: "Reset password instructions sent" }
    end
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

    record_admin_write(action: "users.update_email", target: user) do
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
  end

  def two_factor_authentication
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?
    return render json: { success: false, message: "enabled is required" }, status: :bad_request if params[:enabled].to_s.blank?

    user = find_user_or_render(params[:email])
    return unless user

    record_admin_write(action: "users.two_factor_authentication", target: user) do
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
  end

  def create_comment
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?
    return render json: { success: false, message: "content is required" }, status: :bad_request if params[:content].blank?
    return render json: { success: false, message: "idempotency_key is required" }, status: :bad_request if params[:idempotency_key].blank?

    user = find_user_or_render(params[:email])
    return unless user

    record_admin_write(action: "users.create_comment", target: user) do
      comment = User::CreateAdminCommentService.new(user:, content: params[:content], idempotency_key: params[:idempotency_key], author_id: current_admin_actor_id).perform

      if comment.persisted?
        render json: { success: true, comment: serialize_comment(comment) }
      else
        render json: { success: false, message: comment.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end
    rescue User::CreateAdminCommentService::IdempotencyConflictError
      render json: { success: false, message: "Idempotency key already used with different content" }, status: :conflict
    end
  end

  def mark_compliant
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = find_user_or_render(params[:email])
    return unless user

    record_admin_write(action: "users.mark_compliant", target: user) do
      if user.compliant?
        return render json: { success: true, status: "already_compliant", message: "User is already compliant" }
      end

      note = build_admin_note(user, params[:note]) if params[:note].present?
      return render_invalid_comment(note) if note&.invalid?

      user.mark_compliant!(author_id: current_admin_actor_id)
      note&.save!
      render json: { success: true, status: "marked_compliant", message: "User marked compliant" }
    rescue StateMachines::InvalidTransition => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
  end

  def suspend_for_fraud
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = find_user_or_render(params[:email])
    return unless user

    record_admin_write(action: "users.suspend_for_fraud", target: user) do
      if user.suspended_for_fraud?
        return render json: { success: true, status: "already_suspended", message: "User is already suspended for fraud" }
      end

      suspension_note = build_suspension_note(user) if params[:suspension_note].present?
      return render_invalid_comment(suspension_note) if suspension_note&.invalid?

      user.suspend_for_fraud!(author_id: current_admin_actor_id)
      suspension_note&.save!
      render json: { success: true, status: "suspended_for_fraud", message: "User suspended for fraud" }
    rescue StateMachines::InvalidTransition => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
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

    def last_status_changed_at(user)
      user.comments
        .where(comment_type: Comment::RISK_STATE_COMMENT_TYPES)
        .order(created_at: :desc)
        .first
        &.created_at
    end

    def serialize_user_info(user)
      compliance_info = user.alive_user_compliance_info

      {
        id: user.external_id,
        email: user.form_email,
        name: user.name,
        username: user.username,
        profile_url: user.subdomain_with_protocol,
        country: compliance_info&.country,
        created_at: user.created_at.as_json,
        deleted_at: user.deleted_at&.as_json,
        risk_state: {
          status: suspension_status(user),
          user_risk_state: user.user_risk_state,
          suspended: user.suspended?,
          flagged_for_fraud: user.flagged_for_fraud?,
          flagged_for_tos_violation: user.flagged_for_tos_violation?,
          on_probation: user.on_probation?,
          compliant: user.compliant?,
          last_status_changed_at: last_status_changed_at(user)&.as_json
        },
        two_factor_authentication_enabled: user.two_factor_authentication_enabled?,
        payouts: {
          paused_internally: user.payouts_paused_internally?,
          paused_by_user: user.payouts_paused_by_user?,
          paused_by_source: user.payouts_paused_by_source,
          paused_for_reason: user.payouts_paused_for_reason,
          next_payout_date: user.next_payout_date&.to_s,
          balance_for_next_payout: user.formatted_balance_for_next_payout_date
        },
        stats: {
          sales_count: user.sales.successful.count,
          total_earnings_formatted: Money.from_cents(user.sales_cents_total).format,
          unpaid_balance_formatted: Money.from_cents(user.unpaid_balance_cents).format,
          comments_count: user.comments.size
        }
      }
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
        author_id: current_admin_actor_id,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content:
      )
    end

    def build_suspension_note(user)
      user.comments.new(
        author_id: current_admin_actor_id,
        comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
        content: params[:suspension_note]
      )
    end

    def render_invalid_comment(comment)
      render json: { success: false, message: comment.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
end
