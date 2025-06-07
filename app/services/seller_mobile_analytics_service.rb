# frozen_string_literal: true

class SellerMobileAnalyticsService
  SALES_LIMIT = 300

  def initialize(user, range: "day", query: nil, fields: [])
    @user = user
    @range = range
    @query = query
    @fields = fields
    @result = {}
  end

  def process
    @search_result = PurchaseSearchService.search(search_params)
    add_revenue_to_result
    add_sales_count_to_result
    add_purchases_to_result
    @result
  end

  private
    def search_params
      params = Purchase::CHARGED_SALES_SEARCH_OPTIONS.merge(
        seller: @user,
        exclude_refunded: false,
        exclude_unreversed_chargedback: false,
        size: 0,
        aggs: {
          price_cents_total: { sum: { field: "price_cents" } },
          amount_refunded_cents_total: { sum: { field: "amount_refunded_cents" } },
          chargedback_agg: {
            filter: { term: { not_chargedback_or_chargedback_reversed: false } },
            aggs: {
              price_cents_total: { sum: { field: "price_cents" } },
            }
          }
        }
      )
      params[:track_total_hits] = @fields.include?(:sales_count)
      if @fields.include?(:purchases)
        params[:size] = SALES_LIMIT
        params[:sort] = [{ created_at: { order: :desc } }, { id: { order: :desc } }]
        params[:seller_query] = @query if @query.present?
      end
      unless @range == "all"
        now = Time.now.in_time_zone(@user.timezone)
        raise "Invalid range #{@range}" unless @range.in?(%w[day week month year])
        params[:created_on_or_after] = now.public_send("beginning_of_#{@range}")
      end
      params
    end

    def add_revenue_to_result
      aggregations = @search_result.aggregations
      revenue = \
        aggregations.price_cents_total.value - \
        aggregations.amount_refunded_cents_total.value - \
        aggregations.chargedback_agg.price_cents_total.value
      @result.merge!(
        revenue:,
        formatted_revenue: @user.formatted_dollar_amount(revenue),
      )
    end

    def add_sales_count_to_result
      @result[:sales_count] = @search_result.results.total if @fields.include?(:sales_count)
    end

    def add_purchases_to_result
      return if @fields.exclude?(:purchases)

      purchases_json = @search_result.records.includes(
        :seller,
        :purchaser,
        link: :variant_categories_alive
      ).as_json(creator_app_api: true)
      @result[:purchases] = purchases_json
    end
end
