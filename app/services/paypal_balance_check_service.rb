# frozen_string_literal: true

class PaypalBalanceCheckService
  def initialize
    @payout_amount_cents = calculate_payout_amount_cents
    @current_balance_cents = PaypalPayoutProcessor.current_paypal_balance_cents
    @topup_in_transit_cents = PaypalPayoutProcessor.topup_amount_in_transit * 100
  end

  attr_reader :payout_amount_cents, :current_balance_cents, :topup_in_transit_cents

  def topup_amount_cents
    @topup_amount_cents ||= payout_amount_cents - current_balance_cents - topup_in_transit_cents
  end

  def topup_needed?
    topup_amount_cents > 0
  end

  private
    def calculate_payout_amount_cents
      Balance
        .unpaid
        .where(user_id: Payment
                          .where("created_at > ?", 1.month.ago)
                          .where(processor: "paypal")
                          .select(:user_id))
        .where("date <= ?", User::PayoutSchedule.next_scheduled_payout_date)
        .sum(:amount_cents)
    end
end
