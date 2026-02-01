# frozen_string_literal: true

class CreatorMailerPreview < ActionMailer::Preview
  include CdnUrlHelper
  def gumroad_day_fee_saved
    CreatorMailer.gumroad_day_fee_saved(seller_id: seller&.id)
  end

  def year_in_review
    CreatorMailer.year_in_review(seller:, year:, analytics_data:)
  end

  def year_in_review_with_financial_report
    if seller&.financial_annual_report_url_for(year:).nil?
      seller&.annual_reports&.attach(
        io: Rack::Test::UploadedFile.new("#{Rails.root}/spec/support/fixtures/financial-annual-summary-2022.csv"),
        filename: "Financial summary for 2022.csv",
        content_type: "text/csv",
        metadata: { year: }
      )
    end
    CreatorMailer.year_in_review(
      seller:,
      year:,
      analytics_data:,
      payout_csv_url: seller&.financial_annual_report_url_for(year:)
    )
  end

  def bundles_marketing
    CreatorMailer.bundles_marketing(
      seller_id: seller&.id,
      bundles: [
        {
          type: "best_selling",
          price: 199_99,
          discounted_price: 99_99,
          products: [
            { id: 1, url: "https://example.com/product1", name: "Best Seller 1" },
            { id: 2, url: "https://example.com/product2", name: "Best Seller 2" }
          ]
        },
        {
          type: "year",
          price: 299_99,
          discounted_price: 149_99,
          products: [
            { id: 3, url: "https://example.com/product3", name: "Year Highlight 1" },
            { id: 4, url: "https://example.com/product4", name: "Year Highlight 2" }
          ]
        },
        {
          type: "everything",
          price: 499_99,
          discounted_price: 249_99,
          products: [
            { id: 5, url: "https://example.com/product5", name: "Everything Product 1" },
            { id: 6, url: "https://example.com/product6", name: "Everything Product 2" }
          ]
        }
      ]
    )
  end

  private
    def seller
      @_seller ||= User.first
    end

    def year
      @_year ||= Time.current.year.pred
    end

    def analytics_data
      gpt_buy_list = SendYearInReviewEmailJob.get_buy_list_from_total(total_amount_cents: 4000, currency: seller.currency_type)

      {
        total_views_count: 144,
        total_sales_count: 12,
        top_selling_products: seller&.products&.last(5)&.map do |product|
          ProductPresenter.card_for_email(product:).merge(
            {
              stats: [
                rand(1000..5000),
                rand(10000..50000),
                rand(100000..500000000),
              ]
            }
          )
        end,
        total_products_sold_count: 5,
        total_amount_cents: 4000,
        creator_rank: 2,
        by_country: ["🇪🇸 Spain", "🇷🇴 Romania", "🇦🇪 United Arab Emirates", "🇺🇸 United States", "🌎 Elsewhere"].index_with do
          [
            rand(1000..5000),
            rand(10000..50000),
            rand(10000..50000),
          ]
        end.sort_by { |_, (_, _, total)| -total },
        total_countries_with_sales_count: 4,
        total_unique_customers_count: 8,
        gpt_buy_list: gpt_buy_list,
      }
    end
end
