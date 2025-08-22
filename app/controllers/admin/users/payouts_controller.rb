# frozen_string_literal: true

class Admin::Users::PayoutsController < Admin::BaseController
  before_action :require_user_has_payout_privileges!, except: %i[index show sync sync_all]
  before_action :fetch_payment, only: %i[show retry cancel fail sync]
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

  def show
    @title = "Payout"
  end

  def retry
    unless @payment.cancelled? || @payment.failed? || @payment.returned?
      return render json: { success: false, message: "Failed! Payout is not in a cancelled, failed or returned state." }
    end
    if @payment.user.payments.last != @payment
      return render json: { success: false, message: "Failed! This is not the most recent payout for this user." }
    end

    Payouts.create_payments_for_balances_up_to_date_for_users(@payment.payout_period_end_date, @payment.processor,
                                                              [@payment.user], from_admin: true)
    render json: { success: true }
  end

  def cancel
    return render json: { success: false, message: "Failed! You can only cancel PayPal payouts." } unless @payment.processor == PayoutProcessorType::PAYPAL
    return render json: { success: false, message: "Failed! Payout is not in an unclaimed state." } unless @payment.unclaimed?

    @payment.with_lock do
      @payment.mark_cancelled!
    end

    render json: { success: true, message: "Marked as cancelled." }
  end

  def fail
    error_message = if !@payment.processing?
      "Failed! Payout is not in the processing state."
    elsif @payment.created_at > 2.days.ago
      "Failed! Payout can be marked as failed only two days after creation."
    end
    return render json: { success: false, message: error_message } if error_message

    @payment.with_lock do
      @payment.correlation_id = "Marked as failed by user with ID #{current_user.id}"
      @payment.mark_failed!
    end

    render json: { success: true, message: "Marked as failed." }
  end

  def sync
    return render json: { success: false, message: "Failed! You can only sync PayPal payouts." } unless @payment.processor == PayoutProcessorType::PAYPAL
    return render json: { success: false, message: "Failed! Payout is already in terminal state." } unless Payment::NON_TERMINAL_STATES.include?(@payment.state)

    @payment.with_lock do
      @payment.sync_with_payout_processor
    end

    if @payment.errors.empty?
      render json: { success: true, message: "Synced!" }
    else
      render json: { success: false, message: @payment.errors.first.message }
    end
  end

  def sync_all
    SyncStuckPaypalPayoutsJob.perform_async
    render json: { success: true }
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
    def fetch_payment
      @payment = Payment.find_by(id: params[:id]) || e404
    end

    def fetch_user
      @user = User.find_by(id: params[:user_id]) || e404
    end
end
