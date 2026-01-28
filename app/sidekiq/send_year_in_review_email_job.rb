# frozen_string_literal: true

class SendYearInReviewEmailJob
  include Sidekiq::Job
  include CurrencyHelper
  sidekiq_options retry: 5, queue: :low

  MAX_SHOWCASE_RANK = 1_000

  def perform(seller_id, year, recipient = nil)
    analytics_data = {}
    seller = User.find(seller_id)
    range = Date.new(year).all_year
    payout_csv_url = seller.financial_annual_report_url_for(year:)

    # Don't send email to user without any payouts
    return unless payout_csv_url.present?

    data_by_date = CreatorAnalytics::CachingProxy.new(seller).data_for_dates(range.begin, range.end, by: :date)
    analytics_data[:total_views_count] = data_by_date[:by_date][:views].values.flatten.sum
    analytics_data[:total_sales_count] = data_by_date[:by_date][:sales].values.flatten.sum
    analytics_data[:total_products_sold_count] = data_by_date[:by_date][:sales].transform_values(&:sum).filter { |_, total| total.nonzero? }.keys.count
    analytics_data[:total_amount_cents] = data_by_date[:by_date][:totals].values.flatten.sum

    # Don't send email to creators who received earnings only from affiliate sales
    return if analytics_data[:total_amount_cents].zero?

    analytics_data[:top_selling_products] = map_top_selling_products(seller, data_by_date[:by_date])

    analytics_data[:gpt_buy_list] = self.class.get_buy_list_from_total(
      total_amount_cents: analytics_data[:total_amount_cents],
      currency: seller.currency_type
    )

    data_by_state = CreatorAnalytics::CachingProxy.new(seller).data_for_dates(range.begin, range.end, by: :state)
    analytics_data[:by_country] = build_stats_by_country(data_by_state[:by_state])
    analytics_data[:total_countries_with_sales_count] = analytics_data[:by_country].size
    analytics_data[:total_unique_customers_count] = seller.sales
                                                          .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
                                                          .where("created_at between :start and :end", start: range.begin.in_time_zone(seller.timezone), end: range.end.in_time_zone(seller.timezone).end_of_day)
                                                          .select(:email)
                                                          .distinct
                                                          .count

    creator_rank = seller.rank(year:)
    analytics_data[:creator_rank] = creator_rank if creator_rank.present? && creator_rank <= MAX_SHOWCASE_RANK

    CreatorMailer.year_in_review(
      seller:,
      year:,
      analytics_data:,
      payout_csv_url:,
      recipient:,
    ).deliver_now
  end

  def self.get_buy_list_from_total(total_amount_cents:, currency:)
    formatted_total_in_usd = Money.new(total_amount_cents, currency).format(no_cents_if_whole: true)

    Rails.cache.fetch("gpt_buy_list_#{total_amount_cents}_#{currency}", expires_in: 1.day) do
      content = "Print a numbered list of 5 things that I could buy with #{formatted_total_in_usd}. " \
                "Don't include their prices. Don't start the answer with any introduction, just list the items."
      response = OpenAI::Client.new.chat(parameters: { model: "gpt-4o-mini",
                                                       messages: [{ role: "user", content: }],
                                                       max_tokens: 125 })
      answer = response.dig("choices", 0, "message", "content")
      answer.split("\n").delete_if(&:blank?).map { |item| item.match(/^\d\.\s?(.+)/)[1] }
    end
  end

  private
    def calculate_stats_by_country(data)
      data.values.each_with_object({}) do |hash, result|
        hash.each do |country, stats|
          sum = Array.wrap(stats).sum
          result[country] = result.key?(country) ? result[country] + sum : sum
        end
      end
    end

    def build_stats_by_country(data_by_state)
      totals = calculate_stats_by_country(data_by_state[:totals])
      sales = calculate_stats_by_country(data_by_state[:sales])
      views = calculate_stats_by_country(data_by_state[:views])
      stats_by_country = totals.to_h do |country_name, total_amount_cents|
        [
          Compliance::Countries.country_with_flag_by_name(country_name),
          # SendGrid has a hard limit of 10KB for the custom arguments
          # Ref: https://docs.sendgrid.com/api-reference/mail-send/limitations
          #
          # Mapping to an Array instead of a Hash w/ key/value pairs to cut down the size of the analytics data in half
          [
            views[country_name] || 0, # Views
            sales[country_name], # Sales
            total_amount_cents.nonzero? ? total_amount_cents / 100 : 0, # Total
          ]
        ]
      end

      # Split data by "Elsewhere" vs. All other countries
      all_other_sales, elsewhere_sales = stats_by_country.partition do |(country_key, _)|
        country_key != Compliance::Countries.elsewhere_with_flag
      end

      # Remove countries with $0 sales, sort by total and append "Elsewhere" sales
      all_other_sales
        .filter { |(_, (_, _, total))| total.nonzero? }
        .sort_by { |(_, (_, _, total))| -total }
        .concat(elsewhere_sales)
        .to_h
    end

    def map_top_selling_products(seller, data_by_date)
      top_product_totals = data_by_date[:totals].transform_values(&:sum)
                                                .filter { |_, total| total.nonzero? }
                                                .sort_by { |key, total| [-total, key] }
                                                .first(5)
                                                .to_h
      top_product_permalinks = top_product_totals.keys
      top_product_stats = top_product_permalinks.index_with do |permalink|
        # SendGrid has a hard limit of 10KB for the custom arguments
        # Ref: https://docs.sendgrid.com/api-reference/mail-send/limitations
        #
        # Mapping to an Array instead of a Hash w/ key/value pairs to cut down the size of the analytics data in half
        [
          data_by_date[:views][permalink].sum, # Views
          data_by_date[:sales][permalink].sum, # Sales
          top_product_totals[permalink] / 100, # Total
        ]
      end

      seller.products.where(unique_permalink: top_product_permalinks).map do |product|
        ProductPresenter.card_for_email(product:).merge(
          { stats: top_product_stats[product.unique_permalink] }
        )
      end
    end
end
