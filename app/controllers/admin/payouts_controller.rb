# frozen_string_literal: true

class Admin::PayoutsController < Admin::BaseController
  before_action :fetch_payment, only: %i[show retry cancel fail sync]

  def show
    @title = "Payout"

    render inertia: "Admin/Payouts/Show",
           props: { payout: Admin::PaymentPresenter.new(payment: @payment).props }
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

  private
    def fetch_payment
      if !Payment.external_id?(params[:external_id]) && payment = Payment.find_by(id: params[:external_id])
        return redirect_to admin_payout_path(payment.external_id)
      end

      @payment = Payment.find_by_external_id(params[:external_id]) || e404
    end
end
