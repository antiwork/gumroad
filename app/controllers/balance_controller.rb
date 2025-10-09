# frozen_string_literal: true

class BalanceController < Sellers::BaseController
  include CurrencyHelper
  include PayoutsHelper
  include Pagy::Backend

  PAST_PAYMENTS_PER_PAGE = 3

  before_action :set_on_balance_page

  def index
    authorize :balance

    @title = "Payouts"
    @seller_stats = UserBalanceStatsService.new(user: current_seller).fetch
    pagination, past_payouts = fetch_payouts
    @payout_presenter = PayoutsPresenter.new(
      next_payout_period_data: @seller_stats[:next_payout_period_data],
      processing_payout_periods_data: @seller_stats[:processing_payout_periods_data],
      seller: current_seller,
      pagination:,
      past_payouts:
    )

    render inertia: "Payouts/index",
           props: { payout_presenter: @payout_presenter.props }
  end

  def payments_paged
    authorize :balance, :index?

    pagination, payouts = fetch_payouts

    render json: {
      payouts: payouts.map { payout_period_data(current_seller, _1) },
      pagination:
    }
  end

  private
    def set_on_balance_page
      @on_balance_page = true
    end

    def fetch_payouts
      payouts = current_seller.payments
        .completed
        .displayable
        .order(created_at: :desc)

      payouts_count = payouts.count
      total_pages = (payouts_count / PAST_PAYMENTS_PER_PAGE.to_f).ceil
      page_num = params[:page].to_i

      if page_num <= 0
        page_num = 1
      elsif page_num > total_pages && total_pages != 0
        page_num = total_pages
      end

      pagination, payouts = pagy(payouts, page: page_num, limit: PAST_PAYMENTS_PER_PAGE)
      [PagyPresenter.new(pagination).props, payouts]
    end
end
