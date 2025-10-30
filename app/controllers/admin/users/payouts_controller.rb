# frozen_string_literal: true

class Admin::Users::PayoutsController < Admin::BaseController
  before_action :fetch_user, only: [:index, :pause, :resume]

  RECORDS_PER_PAGE = 20
  private_constant :RECORDS_PER_PAGE

  def index
    @title = "Payouts"
    @payouts = @user.payments
      .order(id: :desc)
      .page_with_kaminari(params[:page])
      .per(RECORDS_PER_PAGE)
  end

  def pause
    reason = params.require(:pause_payouts).permit(:reason)[:reason]
    @user.update!(payouts_paused_internally: true, payouts_paused_by: current_user.id)
    @user.comments.create!(
      author_id: current_user.id,
      content: reason,
      comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED
    ) if reason.present?

    render json: { success: true, message: "User's payouts paused" }
  end

  def resume
    render json: { success: false } and return unless @user.payouts_paused_internally?

    @user.update!(payouts_paused_internally: false, payouts_paused_by: nil)
    @user.comments.create!(
      author_id: current_user.id,
      content: "Payouts resumed.",
      comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED
    )

    render json: { success: true, message: "User's payouts resumed" }
  end

  private
    def fetch_user
      @user = User.find_by(id: params[:user_id]) || e404
    end
end
