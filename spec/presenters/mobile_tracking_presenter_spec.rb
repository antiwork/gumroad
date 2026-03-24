# frozen_string_literal: true

require "spec_helper"

describe MobileTrackingPresenter do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  subject { described_class.new(seller:) }

  describe "#product_props" do
    it "returns the correct props" do
      expect(subject.product_props(product:)).to eq(
        seller_id: seller.external_id,
        analytics: {
          google_analytics_id: nil,
          facebook_pixel_id: nil,
          free_sales: true,
        },
        has_product_third_party_analytics: false,
        has_receipt_third_party_analytics: false,
        third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
        permalink: product.unique_permalink,
        name: product.name,
      )
    end

    context "when the seller has third party analytics on the product page" do
      before do
        create(:third_party_analytic, user: product.user, link: product, location: "product")
      end

      it "returns the correct props" do
        expect(subject.product_props(product:)).to include(
          has_product_third_party_analytics: true,
          has_receipt_third_party_analytics: false,
        )
      end
    end

    context "when the seller has third party analytics on the receipt page" do
      before do
        create(:third_party_analytic, user: product.user, link: product, location: "receipt")
      end

      it "returns the correct props" do
        expect(subject.product_props(product:)).to include(
          has_product_third_party_analytics: false,
          has_receipt_third_party_analytics: true,
        )
      end
    end

    context "when the seller has third party analytics on the receipt page" do
      before do
        create(:third_party_analytic, user: product.user, link: product, location: "all")
      end

      it "returns the correct props" do
        expect(subject.product_props(product:)).to include(
          has_product_third_party_analytics: true,
          has_receipt_third_party_analytics: true,
        )
      end
    end
  end
end
