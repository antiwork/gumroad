# frozen_string_literal: true

describe AnalyticsPresenter do
  let(:seller) { create(:user) }
  let(:presenter) { described_class.new(seller:) }

  let!(:alive_product) { create(:product, user: seller) }
  let!(:deleted_with_sales) { create(:product, user: seller, deleted_at: Time.current) }
  let!(:deleted_without_sales) { create(:product, user: seller, deleted_at: Time.current) }

  # The purchase only needs to exist so deleted_with_sales counts as "has sales" —
  # save without validations so the spec doesn't require Stripe (the purchase factory's
  # financial_transaction_validation otherwise needs a real/stubbed charge).
  before { build(:purchase, link: deleted_with_sales).save!(validate: false) }

  describe "#page_props" do
    it "returns the correct props" do
      expect(presenter.page_props[:products]).to contain_exactly(
        {
          id: alive_product.external_id,
          alive: true,
          unique_permalink: alive_product.unique_permalink,
          name: alive_product.name
        }, {
          id: deleted_with_sales.external_id,
          alive: false,
          unique_permalink: deleted_with_sales.unique_permalink,
          name: deleted_with_sales.name
        }
      )
      expect(presenter.page_props[:country_codes]).to include(
        "united states" => "US",
        "the netherlands" => "NL",
        "russia" => "RU",
        "congo republic" => "CG",
        "macedonia" => "MK",
        "ivory coast" => "CI",
      )
      expect(presenter.page_props[:state_names].first).to eq("Alabama")
      expect(presenter.page_props[:state_names].last).to eq("Other")
      expect(presenter.page_props[:seller_time_zone]).to eq("America/Los_Angeles")
      # No sales history → no stable hourly curve; the frontend falls back to the
      # uniform run-rate projection.
      expect(presenter.page_props[:hourly_sales_curve]).to be_nil
    end

    it "includes the seller's hourly sales curve when history is deep enough" do
      curve = Array.new(24) { |hour| ((hour + 1) / 24.0).round(4) }
      allow_any_instance_of(CreatorAnalytics::HourlySalesCurve).to receive(:cumulative_fractions).and_return(curve)
      expect(presenter.page_props[:hourly_sales_curve]).to eq(curve)
    end

    it "returns the seller's own time zone as an IANA identifier" do
      seller.update!(timezone: "Eastern Time (US & Canada)")
      expect(presenter.page_props[:seller_time_zone]).to eq("America/New_York")
    end
  end
end
