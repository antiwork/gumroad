# frozen_string_literal: true

class PaypalBalanceCheckService
  # payouts_paypal in config/sidekiq_schedule.yml: Friday 10:00 UTC.
  PAYPAL_PAYOUT_HOUR_UTC = 10

  def initialize
    @payout_date = self.class.next_paypal_payout_date
    @payout_amount_cents = calculate_payout_amount_cents
    @current_balance_cents = PaypalPayoutProcessor.current_paypal_balance_cents
    @topup_in_transit_cents = PaypalPayoutProcessor.topup_amount_in_transit * 100
  end

  attr_reader :payout_date, :payout_amount_cents, :current_balance_cents, :topup_in_transit_cents

  def topup_amount_cents
    @topup_amount_cents ||= payout_amount_cents - current_balance_cents - topup_in_transit_cents
  end

  def topup_needed?
    topup_amount_cents > 0
  end

  def self.next_paypal_payout_date
    now = Time.current.utc
    today = now.to_date
    friday = today.friday? ? today : today.next_occurring(:friday)
    run_at = Time.utc(friday.year, friday.month, friday.day, PAYPAL_PAYOUT_HOUR_UTC)
    now >= run_at ? friday + 7 : friday
  end

  private
    def calculate_payout_amount_cents
      Balance
        .unpaid
        .where(user_id: Payment
                          .where("created_at > ?", 1.month.ago)
                          .where(processor: "paypal")
                          .select(:user_id))
        .where("date <= ?", payout_date)
        .sum(:amount_cents)
    end
end
