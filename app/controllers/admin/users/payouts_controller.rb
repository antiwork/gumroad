# frozen_string_literal: true

class Admin::Users::PayoutsController < Admin::BaseController
  include Pagy::Backend

  before_action :fetch_user, only: [:index, :pause, :resume]

  RECORDS_PER_PAGE = 20
  private_constant :RECORDS_PER_PAGE

  def index
    @title = "Payouts"

    pagination, @payouts = pagy(
      @user.payments.order(id: :desc),
      limit: params[:per_page] || RECORDS_PER_PAGE,
      page: params[:page]
    )

    render inertia: "Admin/Users/Payouts/Index",
           props: {
             payouts: @payouts.includes(:user, bank_account: :credit_card).map { Admin::PaymentPresenter.new(payment: _1).props },
             pagination: PagyPresenter.new(pagination).props
           }
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
      @user = User.find_by_external_id(params[:user_external_id]) || e404
    end
end
