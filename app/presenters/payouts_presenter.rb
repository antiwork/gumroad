# frozen_string_literal: true

class PayoutsPresenter
  include CurrencyHelper
  include PayoutsHelper
  include Pagy::Backend

  PAST_PAYMENTS_PER_PAGE = 3

  attr_reader :seller, :params

  def initialize(seller:, params: {})
    @seller = seller
    @params = params
  end

  def past_payout_period_data
    past_payouts.map { payout_period_data(seller, _1) }
  end

  def next_payout_period_data
    seller_stats[:next_payout_period_data]&.merge(
      has_stripe_connect: seller.stripe_connect_account.present?
    )
  end

  def processing_payout_periods_data
    seller_stats[:processing_payout_periods_data].map do |item|
      item.merge(has_stripe_connect: seller.stripe_connect_account.present?)
    end
  end

  def instant_payout_data
    return nil unless seller.instant_payouts_supported?

    {
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
    }
  end

  def pagination_data
    PagyPresenter.new(pagination).props
  end

  private
    def seller_stats
      @seller_stats ||= UserBalanceStatsService.new(user: seller).fetch
    end

    def pagination
      paginated_payouts.first
    end

    def past_payouts
      paginated_payouts.last
    end

    def paginated_payouts
      @paginated_payouts ||= begin
        payouts = seller.payments
          .completed
          .displayable
          .order(created_at: :desc)

        page_num = validated_page_num(payouts.count)
        pagy(payouts, page: page_num, limit: PAST_PAYMENTS_PER_PAGE)
      end
    end

    def validated_page_num(payouts_count)
      total_pages = (payouts_count / PAST_PAYMENTS_PER_PAGE.to_f).ceil
      page_num = params[:page].to_i

      if page_num <= 0
        1
      elsif page_num > total_pages && total_pages != 0
        total_pages
      else
        page_num
      end
    end
end
