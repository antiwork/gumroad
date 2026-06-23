# frozen_string_literal: true

require "spec_helper"

describe PurchaseSellerAnalyticsPresenter do
  describe "#props" do
    it "returns nil when there is no purchase" do
      expect(described_class.new(nil).props).to be_nil
    end

    it "returns nil when the seller has no third-party analytics configured" do
      purchase = create(:free_purchase, link: create(:product))

      expect(described_class.new(purchase).props).to be_nil
    end

    context "when the seller has a Facebook pixel configured" do
      let(:seller) { create(:user, facebook_pixel_id: "1234567890") }
      let(:product) { create(:product, user: seller, name: "My Product") }
      let(:purchase) { create(:free_purchase, link: product, displayed_price_cents: 14_99) }

      it "returns the seller id, analytics data, and purchase event payload" do
        props = described_class.new(purchase).props

        expect(props[:seller_id]).to eq(seller.external_id)
        expect(props[:analytics][:facebook_pixel_id]).to eq("1234567890")
        expect(props[:purchase_event]).to include(
          permalink: product.unique_permalink,
          purchase_external_id: purchase.external_id,
          product_name: "My Product",
          value: 14_99,
          currency: purchase.displayed_price_currency_type.to_s,
          quantity: purchase.quantity,
        )
        expect(props[:purchase_event][:buyer_currency_display]).to be_present
      end
    end

    it "returns the analytics payload when only Google Analytics is configured" do
      seller = create(:user, google_analytics_id: "G-ABC123")
      purchase = create(:free_purchase, link: create(:product, user: seller))

      props = described_class.new(purchase).props

      expect(props[:analytics][:google_analytics_id]).to eq("G-ABC123")
      expect(props[:analytics][:facebook_pixel_id]).to be_nil
    end
  end
end
