# frozen_string_literal: true

class Admin::PaydaysController < Admin::BaseController
  # Pay the seller for all their balances up to and including `params[:payout_period_end_date]`.
  def pay_user
    user = User.find(params[:id])
    date = Date.parse(payday_params[:payout_period_end_date])

    payout_processor_type = if payday_params[:payout_processor] == PayoutProcessorType::STRIPE
      PayoutProcessorType::STRIPE
    elsif payday_params[:payout_processor] == PayoutProcessorType::PAYPAL
      user.update!(should_paypal_payout_be_split: true) if payday_params[:should_split_the_amount].present?
      PayoutProcessorType::PAYPAL
    end

    payments = Payouts.create_payments_for_balances_up_to_date_for_users(date, payout_processor_type, [user], from_admin: true)

    if request.format.json?
      payment = payments.first&.first
      if payment.blank? || payment.failed?
        render json: { message: payment&.errors&.full_messages&.first || "Payment was not sent." }, status: :unprocessable_entity
      else
        head :no_content
      end
    else
      redirect_to admin_user_url(user), notice: payments.first.present? && !payments.first.first.failed? ? "Payment was sent." : "Payment was not sent."
    end
  end

  private
    def payday_params
      params.require(:payday).permit(:payout_period_end_date, :payout_processor, :should_split_the_amount)
    end
end
