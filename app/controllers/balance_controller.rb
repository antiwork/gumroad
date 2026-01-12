# frozen_string_literal: true

class BalanceController < Sellers::BaseController
  layout "inertia", only: [:index]

  def index
    authorize :balance

    @title = "Payouts"

    payouts_presenter = PayoutsPresenter.new(seller: current_seller, params:)

    render inertia: "Payouts/Index",
           props: {
             next_payout_period_data: -> { payouts_presenter.next_payout_period_data },
             processing_payout_periods_data: -> { payouts_presenter.processing_payout_periods_data },
             payouts_status: -> { current_seller.payouts_status },
             payouts_paused_by: -> { current_seller.payouts_paused_by_source },
             payouts_paused_for_reason: -> { current_seller.payouts_paused_for_reason },
             instant_payout: -> { payouts_presenter.instant_payout_data },
             show_instant_payouts_notice: -> { current_seller.eligible_for_instant_payouts? && !current_seller.active_bank_account&.supports_instant_payouts? },
             tax_center_enabled: -> { Feature.active?(:tax_center, current_seller) },
             past_payout_period_data: InertiaRails.merge { payouts_presenter.past_payout_period_data },
             pagination: -> { payouts_presenter.pagination_data }
           }
  end
end
