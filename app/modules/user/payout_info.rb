# frozen_string_literal: true

module User::PayoutInfo
  include CurrencyHelper

  def payout_info
    @payout_info ||= {
      active_bank_account: active_bank_account&.as_json(only: %i[type account_holder_full_name], methods: %i[formatted_account]),
      payment_address:,
      payouts_paused_by_source:,
      payouts_paused_for_reason: comments.with_type_payouts_paused.last&.content,
      manual_payout_info:
    }
  end

  private
    def manual_payout_info
      return unless last_payout_to_user.nil? || %w(completed failed returned reversed cancelled).include?(last_payout_to_user.state)
      return unless stripe_payable_from_admin? || paypal_payable_from_admin?

      {
        stripe: stripe_payable_info,
        paypal: paypal_payable_info,
        unpaid_balance_up_to_date: unpaid_balance_cents_up_to_date(manual_payout_period_end_date),
        currency: stripe_account&.currency,
        ask_confirmation: (stripe_payable_from_admin? || paypal_payable_from_admin?) && !stripe_payable? && !paypal_payable?,
        manual_payout_period_end_date:
      }
    end

    def stripe_payable_info
      return unless stripe_payable_from_admin?

      {
        unpaid_balance_held_by_gumroad: formatted_dollar_amount(unpaid_balance_cents_up_to_date_held_by_gumroad(manual_payout_period_end_date)),
        unpaid_balance_held_by_stripe: formatted_amount_in_currency(unpaid_balance_holding_cents_up_to_date_held_by_stripe(manual_payout_period_end_date), stripe_account&.currency)
      }
    end

    def paypal_payable_info
      return unless paypal_payable_from_admin?

      {
        should_payout_be_split: should_paypal_payout_be_split?,
        split_payment_by_cents: PaypalPayoutProcessor.split_payment_by_cents(self)
      }
    end

    def stripe_payable?
      Payouts.is_user_payable(self, manual_payout_period_end_date, processor_type: PayoutProcessorType::STRIPE)
    end

    def paypal_payable?
      Payouts.is_user_payable(self, manual_payout_period_end_date, processor_type: PayoutProcessorType::PAYPAL)
    end

    def stripe_payable_from_admin?
      Payouts.is_user_payable(self, manual_payout_period_end_date, processor_type: PayoutProcessorType::STRIPE, from_admin: true)
    end

    def paypal_payable_from_admin?
      Payouts.is_user_payable(self, manual_payout_period_end_date, processor_type: PayoutProcessorType::PAYPAL, from_admin: true)
    end

    def manual_payout_period_end_date
      User::PayoutSchedule.manual_payout_end_date
    end

    def last_payout_to_user
      payments.last
    end
end
