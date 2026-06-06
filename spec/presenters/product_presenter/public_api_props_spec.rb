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
end
