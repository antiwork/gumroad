# frozen_string_literal: true

class PayoutsPresenter
  include CurrencyHelper
  include PayoutsHelper

  attr_reader :next_payout_period_data, :processing_payout_periods_data, :seller, :past_payouts, :pagination

  def initialize(next_payout_period_data:, processing_payout_periods_data:, seller:, past_payouts:, pagination:)
    @next_payout_period_data = next_payout_period_data
    @processing_payout_periods_data = processing_payout_periods_data
    @seller = seller
    @past_payouts = past_payouts
    @pagination = pagination
  end

  def props
    {
      next_payout_period_data: next_payout_period_data&.merge(
        has_stripe_connect: seller.stripe_connect_account.present?
      ),
      processing_payout_periods_data: processing_payout_periods_data.map do |item|
        item.merge(has_stripe_connect: seller.stripe_connect_account.present?)
      end,
      payouts_status: seller.payouts_status,
      payouts_paused_by: seller.payouts_paused_by_source,
      payouts_paused_for_reason: seller.payouts_paused_for_reason,
      past_payout_period_data: past_payouts.map { payout_period_data(seller, _1) },
      instant_payout: seller.instant_payouts_supported? ? {
        payable_amount_cents: seller.instantly_payable_unpaid_balance_cents,
        payable_balances: seller.instantly_payable_unpaid_balances.sort_by(&:date).reverse.map do |balance|
          {
            id: balance.external_id,
            date: balance.date,
            amount_cents: balance.holding_amount_cents,
          }
        end,
        bank_account_type: seller.active_bank_account.bank_account_type,
        bank_name: seller.active_bank_account.bank_name,
        routing_number: seller.active_bank_account.routing_number,
        account_number: seller.active_bank_account.account_number_visual,
      } : nil,
      show_instant_payouts_notice: seller.eligible_for_instant_payouts? && !seller.active_bank_account&.supports_instant_payouts?,
      pagination:,
    }
  end
end
