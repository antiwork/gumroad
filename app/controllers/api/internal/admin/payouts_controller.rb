# frozen_string_literal: true

class Api::Internal::Admin::PayoutsController < Api::Internal::Admin::BaseController
  before_action :fetch_user

  def list
    payouts = @user.payments.order(created_at: :desc).limit(5).map { serialize_payout(_1) }
    payout_note = @user.comments.with_type_payout_note.where(author_id: GUMROAD_ADMIN_ID).last&.content

    render json: {
      success: true,
      last_payouts: payouts,
      next_payout_date: @user.next_payout_date,
      balance_for_next_payout: @user.formatted_balance_for_next_payout_date,
      payout_note:
    }
  end

  def pause
    record_admin_write(action: "payouts.pause", target: @user) do
      if @user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_ADMIN
        return render json: {
          success: true,
          status: "already_paused",
          message: "Payouts are already paused by admin",
          payouts_paused: true
        }
      end

      reason = params[:reason].to_s.strip.presence

      User.transaction do
        @user.update!(payouts_paused_internally: true, payouts_paused_by: current_admin_actor_id)
        if reason.present?
          @user.comments.create!(
            author_id: current_admin_actor_id,
            comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
            content: reason
          )
        end
      end

      render json: {
        success: true,
        message: "Payouts paused for #{@user.email}",
        payouts_paused: true
      }
    end
  end

  def resume
    record_admin_write(action: "payouts.resume", target: @user) do
      unless @user.payouts_paused_internally?
        return render json: {
          success: true,
          status: "not_paused",
          message: "Payouts are not paused by admin",
          payouts_paused: @user.payouts_paused?
        }
      end

      User.transaction do
        @user.update!(payouts_paused_internally: false, payouts_paused_by: nil)
        @user.comments.create!(
          author_id: current_admin_actor_id,
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED,
          content: "Payouts resumed."
        )
      end

      render json: {
        success: true,
        message: "Payouts resumed for #{@user.email}",
        payouts_paused: @user.reload.payouts_paused?
      }
    end
  end

  private
    def fetch_user
      return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

      @user = User.alive.by_email(params[:email]).first
      render json: { success: false, message: "User not found" }, status: :not_found if @user.blank?
    end
end
