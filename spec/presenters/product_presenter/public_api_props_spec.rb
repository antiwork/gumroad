# frozen_string_literal: true

require "spec_helper"

describe ProductPresenter::PublicApiProps do
  include Rails.application.routes.url_helpers

  let(:seller) { create(:user, name: "Testy", username: "testy", created_at: 60.days.ago) }
  let(:product) { create(:product, user: seller, name: "My Product", price_cents: 600) }
  let(:presenter) { described_class.new(product:) }

  before { product.save_custom_summary("A great product") }

  describe "#props" do
    subject(:props) { presenter.props }

    it "exposes the documented public identity fields" do
      expect(props[:api_version]).to eq(described_class::API_VERSION)
      expect(props[:id]).to eq(product.external_id)
      expect(props[:permalink]).to eq(product.general_permalink)
      expect(props[:name]).to eq("My Product")
      expect(props[:native_type]).to eq(product.native_type)
      expect(props[:url]).to eq(product.long_url)
      expect(props[:created_at]).to eq(product.created_at.iso8601)
      expect(props[:updated_at]).to eq(product.updated_at.iso8601)
    end

    it "uses the public permalink from the product URL" do
      product.update!(custom_permalink: "custom-product")
      expect(props[:permalink]).to eq("custom-product")
      expect(props[:url]).to end_with("/l/custom-product")
    end

    it "exposes pricing fields" do
      expect(props[:price_cents]).to eq(600)
      expect(props[:currency_code]).to eq("usd")
      expect(props[:price_formatted]).to eq(product.price_formatted_verbose)
      expect(props[:is_pay_what_you_want]).to be(false)
      expect(props[:suggested_price_cents]).to be_nil
      expect(props[:is_recurring_billing]).to be(false)
    end

    it "exposes content fields" do
      product.save_custom_attributes([{ "name" => "Format", "value" => "PDF" }])
      expect(props[:description_html]).to eq(product.html_safe_description)
      expect(props[:summary]).to eq("A great product")
      expect(props[:attributes]).to include({ name: "Format", value: "PDF" })
      expect(props).to have_key(:covers)
    end

    it "exposes the public seller byline only (no PII)" do
      seller_props = props[:seller]
      expect(seller_props[:name]).to eq("Testy")
      expect(seller_props).to have_key(:avatar_url)
      expect(seller_props).to have_key(:profile_url)
      expect(seller_props).not_to have_key(:email)
    end

    it "never includes buyer-specific, admin, or analytics fields" do
      %i[purchase buyer wishlists can_edit analytics has_third_party_analytics
         is_compliance_blocked admin_info].each do |forbidden|
        expect(props).not_to have_key(forbidden)
      end
    end

    describe "sales_count respects the creator privacy toggle" do
      before { allow(product).to receive(:successful_sales_count).and_return(2) }

      it "is nil when should_show_sales_count is false" do
        product.update!(should_show_sales_count: false)
        expect(props[:sales_count]).to be_nil
      end

      it "is the successful sales count when should_show_sales_count is true" do
        product.update!(should_show_sales_count: true)
        expect(props[:sales_count]).to eq(2)
      end

      it "uses the shared cached sales count" do
        product.update!(should_show_sales_count: true)
        expect(ProductPresenter).to receive(:cached_sales_count).with(product).and_return(2)
        expect(props[:sales_count]).to eq(2)
      end
    end

    describe "ratings respect the display_product_reviews toggle" do
      it "is nil when reviews are hidden" do
        product.update!(display_product_reviews: false)
        expect(props[:ratings]).to be_nil
      end

      it "is the rating stats when reviews are shown" do
        product.update!(display_product_reviews: true)
        expect(props[:ratings]).to eq(product.rating_stats)
        expect(props[:ratings][:percentages]).to eq(product.rating_percentages.values)
      end
    end

    describe "reviews respect the display_product_reviews toggle" do
      let(:reviews) do
        [
          create(:product_review, link: product, purchase: create(:purchase, link: product), rating: 5, message: "Best purchase of the year"),
          create(:product_review, link: product, purchase: create(:purchase, link: product), rating: 2, message: "Not for me"),
        ]
      end

      before { reviews }

      it "is nil when the seller hides reviews" do
        product.update!(display_product_reviews: false)
        expect(props[:reviews]).to be_nil
      end

      it "exposes the review text, rating, rater and date when reviews are shown" do
        product.update!(display_product_reviews: true)

        expect(props[:reviews].size).to eq(2)
        expect(props[:reviews].first).to include(rating: 5, message: "Best purchase of the year")
        expect(props[:reviews].first[:rater]).to include(:name, :avatar_url)
        expect(props[:reviews].first[:created_at]).to be_present
        expect(props[:reviews].map { |review| review[:rating] }).to eq([5, 2])
      end

      it "never exposes purchase identifiers" do
        product.update!(display_product_reviews: true)

        props[:reviews].each do |review|
          expect(review).not_to have_key(:purchase_id)
          expect(review[:rater]).not_to have_key(:email)
        end
      end

      it "keeps a buyer who chose Anonymous anonymous" do
        product.update!(display_product_reviews: true)
        reviews.first.update!(anonymous: true)

        expect(props[:reviews].first[:rater][:name]).to eq("Anonymous")
      end

      it "caps the list and keeps it in product-page order" do
        product.update!(display_product_reviews: true)
        4.times { create(:product_review, link: product, purchase: create(:purchase, link: product), rating: 4, message: "Solid") }

        expect(props[:reviews].size).to eq(described_class::PUBLIC_REVIEW_LIMIT)
        expect(props[:reviews].first[:rating]).to eq(5)
      end

      it "omits message-less reviews the product page does not show" do
        product.update!(display_product_reviews: true)
        reviews.first.update!(message: nil, has_message: false)

        expect(props[:reviews].map { |review| review[:message] }).not_to include(nil)
      end

      it "loads the reviews without a query per review" do
        product.update!(display_product_reviews: true)
        two_reviews = count_queries { described_class.new(product: Link.find(product.id)).props }

        3.times { create(:product_review, link: product, purchase: create(:purchase, link: product), rating: 4, message: "Solid") }
        five_reviews = count_queries { described_class.new(product: Link.find(product.id)).props }

        expect(five_reviews).to eq(two_reviews)
      end
    end

    context "pay-what-you-want product" do
      let(:product) { create(:product, user: seller, customizable_price: true, price_cents: 500, suggested_price_cents: 800) }

      it "exposes PWYW pricing" do
        expect(props[:is_pay_what_you_want]).to be(true)
        expect(props[:suggested_price_cents]).to eq(800)
      end
    end

    context "membership product" do
      let(:product) { create(:membership_product, user: seller) }

      it "exposes recurrence and membership flags" do
        expect(props[:is_recurring_billing]).to be(true)
        expect(props[:is_tiered_membership]).to be(true)
        expect(props[:recurrences]).to eq(product.recurrences.as_json)
      end
    end

    context "published / unpublished state" do
      it "reports is_published true for a live product" do
        expect(props[:is_published]).to be(true)
      end

      it "reports is_published false for a draft" do
        product.update!(draft: true)
        expect(props[:is_published]).to be(false)
      end
    end

    describe "seller object" do
      it "is always an object with the documented keys" do
        seller_props = props[:seller]
        expect(seller_props).to be_a(Hash)
        expect(seller_props[:name]).to eq(seller.name_or_username)
        expect(seller_props).to have_key(:avatar_url)
        expect(seller_props).to have_key(:profile_url)
        expect(seller_props).to have_key(:is_verified)
      end

      it "falls back to a plain object (never nil) when author_byline_props is nil" do
        allow_any_instance_of(UserPresenter).to receive(:author_byline_props).and_return(nil)
        seller_props = props[:seller]
        expect(seller_props).to be_a(Hash)
        expect(seller_props[:id]).to eq(seller.external_id)
        expect(seller_props[:name]).to eq(seller.name_or_username)
        expect(seller_props[:is_verified]).to be(false)
      end

      it "uses the seller custom domain for the profile_url when present" do
        custom_domain_url = "https://shop.example.com/"
        presenter = described_class.new(product:, seller_custom_domain_url: custom_domain_url)
        expect(presenter.props[:seller][:profile_url]).to eq(seller.profile_url(custom_domain_url:))
      end
    end

    describe "refund_policy" do
      let(:refund_policy) do
        build(:product_refund_policy, product:, seller:, fine_print: "Line one\nLine two")
      end

      before do
        allow_any_instance_of(User).to receive(:account_level_refund_policy_enabled?).and_return(false)
        allow(product).to receive(:product_refund_policy_enabled?).and_return(true)
        allow(product).to receive(:product_refund_policy).and_return(refund_policy)
      end

      it "renders fine_print with simple_format (HTML) to mirror the product page" do
        # ProductPresenter::ProductProps wraps fine_print with simple_format and
        # the page renders it via dangerouslySetInnerHTML — the public API must
        # ship the same HTML, not the raw text.
        expect(props[:refund_policy][:title]).to eq(refund_policy.title)
        expect(props[:refund_policy][:fine_print]).to eq(
          ActionController::Base.helpers.simple_format("Line one\nLine two")
        )
        expect(props[:refund_policy][:fine_print]).to include("<p>", "<br />")
      end
    end
  end

  describe "display_price" do
    let(:seller) { create(:user, disable_buyer_local_currency: false) }
    let(:french_ip) { "2.2.2.2" }

    before do
      allow(Feature).to receive(:active?).and_call_original
      allow(Feature).to receive(:active?).with(:buyer_local_currency, seller).and_return(true)
      allow(Feature).to receive(:active?).with(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller).and_return(false)
      allow(Feature).to receive(:active?).with(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller).and_return(false)
      allow(GeoIp).to receive(:lookup).with(french_ip).and_return(
        GeoIp::Result.new(country_name: "FR", country_code: "FR", region_name: nil, city_name: nil, postal_code: nil, latitude: nil, longitude: nil)
      )
      allow_any_instance_of(Pages::ProductPrices).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))
    end

    def display_price(**kwargs)
      described_class.new(product:, **kwargs).props[:display_price]
    end

    it "is null when no visitor is given" do
      expect(display_price).to be_nil
    end

    it "converts into the visitor's currency and leaves the existing price fields untouched" do
      product.update!(price_cents: 1400)
      props = described_class.new(product:, ip: french_ip).props

      expect(props[:display_price]).to eq(price: "€11.20", price_cents: 1120, currency_code: "eur", localized: true)
      expect(props.slice(:price_cents, :currency_code, :price_formatted)).to eq(price_cents: 1400, currency_code: "usd", price_formatted: "$14")
    end

    it "honours an explicit currency over the IP" do
      allow(GeoIp).to receive(:lookup).with("8.8.8.8").and_return(nil)
      expect(display_price(ip: "8.8.8.8", preferred_currency: "eur")).to include(currency_code: "eur", localized: true)
    end

    it "falls back to the product's own currency when the visitor's cannot be used" do
      expect(display_price(ip: "8.8.8.8")).to include(currency_code: "usd", localized: false)
    end

    it "applies the default discount and reports the original price" do
      product.update!(price_cents: 1000)
      product.update!(default_offer_code: create(:offer_code, user: seller, products: [product], amount_cents: 200))

      expect(display_price(ip: french_ip)).to include(price_cents: 640, original_price_cents: 800, localized: true)
    end

    it "keeps the recurrence wording on a membership" do
      membership = create(:membership_product, user: seller, price_cents: 500)
      props = described_class.new(product: membership, ip: french_ip).props

      expect(props[:display_price][:price]).to eq("€4 a month")
    end
  end
end
