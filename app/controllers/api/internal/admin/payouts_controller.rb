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

  private
    def fetch_user
      return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

      @user = User.alive.by_email(params[:email]).first
      render json: { success: false, message: "User not found" }, status: :not_found if @user.blank?
    end
end
