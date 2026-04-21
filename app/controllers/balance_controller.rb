# frozen_string_literal: true

class BalanceController < Sellers::BaseController
  layout "inertia", only: [:index]


  def index
    authorize :balance

    set_meta_tag(title: "Payouts")

    payouts_presenter = PayoutsPresenter.new(seller: current_seller, params:)

    render inertia: "Payouts/Index",
           props: {
             next_payout_period_data: -> { payouts_presenter.next_payout_period_data },
             processing_payout_periods_data: -> { payouts_presenter.processing_payout_periods_data },
             payouts_status: -> { current_seller.payouts_status },
             payouts_paused_by: -> { current_seller.payouts_paused_by_source },
             instant_payout: -> { payouts_presenter.instant_payout_data },
             show_instant_payouts_notice: -> { current_seller.eligible_for_instant_payouts? && !current_seller.active_bank_account&.supports_instant_payouts? },
             tax_center_enabled: -> { current_seller.tax_center_enabled? },
             past_payout_period_data: InertiaRails.merge { payouts_presenter.past_payout_period_data },
             pagination: -> { payouts_presenter.pagination_data },
             scheduled_payout: -> { scheduled_payout_props }
           }
  end

  private
    def scheduled_payout_props
      return nil if !current_seller.suspended?

      sp = current_seller.scheduled_payouts.where(status: %w[pending flagged held executed]).order(id: :desc).first
      return nil if sp.nil?

      {
        action: sp.action,
        status: sp.status,
        scheduled_at: sp.scheduled_at,
        payout_amount_cents: sp.payout_amount_cents
      }
    end
end
