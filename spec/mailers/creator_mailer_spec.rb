# frozen_string_literal: true

require "spec_helper"

describe CreatorMailer do
  describe "#gumroad_day_fee_saved" do
    it "includes details of fee saved on Gumroad day" do
      seller = create(:user, gumroad_day_timezone: "Mumbai")
      create(:purchase,
             price_cents: 40620,
             link: create(:product, user: seller),
             created_at: DateTime.new(2024, 4, 4, 12, 0, 0, "+05:30"))

      mail = CreatorMailer.gumroad_day_fee_saved(seller_id: seller.id)

      expect(mail.subject).to eq("You saved $40.62 in fees on Gumroad Day!")

      body = mail.body.encoded

      expect(body).to have_text("You saved $40.62 in fees on Gumroad Day!")
      expect(body).to have_text("Thanks for being a part of #GumroadDay2024!")
      expect(body).to have_text("As a reminder, April 4, 2024 was Gumroad's 13th birthday and we celebrated by lowering Gumroad fees to 0% flat, saving you a total of $40.62 in Gumroad fees.")
      expect(body).to have_text("See you next year!")
      expect(body).to have_text("Best,")
      expect(body).to have_text("Sahil and the Gumroad team")
      expect(body).to have_text("PS. View the #GumroadDay2024 hashtag on Twitter and Instagram for inspiration for next year.")
    end
  end

  describe "#bundles_marketing" do
    let(:seller) { create(:user) }

    let(:bundles) do
      [
        {
          type: Product::BundlesMarketing::BEST_SELLING_BUNDLE,
          price: 199_99,
          discounted_price: 99_99,
          products: [
            { id: 1, url: "https://example.com/product1", name: "Best Seller 1" },
            { id: 2, url: "https://example.com/product2", name: "Best Seller 2" }
          ]
        },
        {
          type: Product::BundlesMarketing::YEAR_BUNDLE,
          price: 299_99,
          discounted_price: 149_99,
          products: [
            { id: 3, url: "https://example.com/product3", name: "Year Highlight 1" },
            { id: 4, url: "https://example.com/product4", name: "Year Highlight 2" }
          ]
        },
        {
          type: Product::BundlesMarketing::EVERYTHING_BUNDLE,
          price: 499_99,
          discounted_price: 249_99,
          products: [
            { id: 5, url: "https://example.com/product5", name: "Everything Product 1" },
            { id: 6, url: "https://example.com/product6", name: "Everything Product 2" }
          ]
        }
      ]
    end

    it "includes the correct text and product links" do
      mail = CreatorMailer.bundles_marketing(seller_id: seller.id, bundles: bundles)
      expect(mail.subject).to eq("Join top creators who have sold over $300,000 of bundles")

      body = mail.body.encoded

      expect(body).to have_text("We've put together some awesome bundles of your top products - they're ready and waiting for you. Gumroad creators have already made over $300,000 selling bundles. Launch your bundles now with just a few clicks!")

      expect(body).to have_text("Best Selling Bundle")
      expect(body).to have_link("Best Seller 1", href: "https://example.com/product1")
      expect(body).to have_link("Best Seller 2", href: "https://example.com/product2")
      expect(body).to have_text("$199.99")
      expect(body).to have_text("$99.99")
      expect(body).to have_link("Edit and launch", href: create_from_email_bundles_url(type: Product::BundlesMarketing::BEST_SELLING_BUNDLE, price: 99_99, products: [1, 2]))

      expect(body).to have_text("#{1.year.ago.year} Bundle")
      expect(body).to have_link("Year Highlight 1", href: "https://example.com/product3")
      expect(body).to have_link("Year Highlight 2", href: "https://example.com/product4")
      expect(body).to have_text("$299.99")
      expect(body).to have_text("$149.99")
      expect(body).to have_link("Edit and launch", href: create_from_email_bundles_url(type: Product::BundlesMarketing::YEAR_BUNDLE, price: 149_99, products: [3, 4]))

      expect(body).to have_text("Everything Bundle")
      expect(body).to have_link("Everything Product 1", href: "https://example.com/product5")
      expect(body).to have_link("Everything Product 2", href: "https://example.com/product6")
      expect(body).to have_text("$499.99")
      expect(body).to have_text("$249.99")
      expect(body).to have_link("Edit and launch", href: create_from_email_bundles_url(type: Product::BundlesMarketing::EVERYTHING_BUNDLE, price: 249_99, products: [5, 6]))
    end
  end

  describe "#year_in_review" do
    let(:seller) { create(:user) }
    let(:year) { 2024 }
    let(:analytics_data) do
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
        total_amount_cents: 5000,
        creator_rank: 2,
        by_country: ["🇪🇸 Spain", "🇷🇴 Romania", "🇦🇪 United Arab Emirates", "🇺🇸 United States", "🌎 Elsewhere"].index_with do
          [
            5,
            1_500,
            10,
          ]
        end.sort_by { |_, (_, _, total)| -total },
        total_countries_with_sales_count: 5,
        total_unique_customers_count: 8
      }
    end

    context "when the seller is earning in USD" do
      it "includes the correct text and product links" do
        mail = CreatorMailer.year_in_review(seller:, year:, analytics_data:)

        expect(mail.subject).to eq("Your 2024 in review")

        body = mail.body.encoded

        expect(body).to have_text("Your year on Gumroad in review")
        expect(body).to have_text("You ranked #2 among all creators")
        expect(body).to have_text("You sold products in 5 countries")
        expect(body).to have_text("Sales 12", normalize_ws: true)
        expect(body).to have_text("Views 144", normalize_ws: true)
        expect(body).to have_text("Unique customers 8", normalize_ws: true)
        expect(body).to have_text("Products sold 5", normalize_ws: true)
        expect(body).to have_text("United States 5 1.5K $10", normalize_ws: true)
        expect(body).to have_text("Spain 5 1.5K $10", normalize_ws: true)
        expect(body).to have_text("Romania 5 1.5K $10", normalize_ws: true)
        expect(body).to have_text("United Arab Emirates 5 1.5K $10", normalize_ws: true)
        expect(body).to have_text("Elsewhere 5 1.5K $10", normalize_ws: true)
        expect(body).to have_text("You earned a total of $50", normalize_ws: true)
      end
    end

    context "when the seller is earning in GBP" do
      before do
        seller.update!(currency_type: "gbp")
      end

      it "converts the total amount to GBP" do
        mail = CreatorMailer.year_in_review(seller:, year:, analytics_data:)

        expect(mail.subject).to eq("Your 2024 in review")

        body = mail.body.encoded

        expect(body).to have_text("United States 5 1.5K £6.5", normalize_ws: true)
        expect(body).to have_text("Spain 5 1.5K £6.5", normalize_ws: true)
        expect(body).to have_text("Romania 5 1.5K £6.5", normalize_ws: true)
        expect(body).to have_text("United Arab Emirates 5 1.5K £6.5", normalize_ws: true)
        expect(body).to have_text("Elsewhere 5 1.5K £6.5", normalize_ws: true)
        expect(body).to have_text("You earned a total of £32", normalize_ws: true)
      end
    end
  end
end
