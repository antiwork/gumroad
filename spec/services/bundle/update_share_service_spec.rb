# frozen_string_literal: true

require "spec_helper"

describe Bundle::UpdateShareService do
  describe "#perform" do
    let(:seller) { create(:named_seller, :eligible_for_service_products) }
    let(:bundle) { create(:product, :bundle, user: seller, price_cents: 2000) }

    it "sets hide_bundle_product_reviews on the bundle" do
      described_class.new(bundle:, hide_bundle_product_reviews: true).perform

      expect(bundle.reload.hide_bundle_product_reviews).to eq(true)
    end

    it "clears hide_bundle_product_reviews when explicitly false" do
      bundle.update!(hide_bundle_product_reviews: true)

      described_class.new(bundle:, hide_bundle_product_reviews: false).perform

      expect(bundle.reload.hide_bundle_product_reviews).to eq(false)
    end

    it "leaves hide_bundle_product_reviews unchanged when omitted" do
      bundle.update!(hide_bundle_product_reviews: true)

      described_class.new(bundle:, section_ids: []).perform

      expect(bundle.reload.hide_bundle_product_reviews).to eq(true)
    end

    it "locks the bundle's row before it takes the profile sections lock, the order the product sections writer takes them" do
      expect(bundle).to receive(:lock!).ordered.and_call_original
      expect(bundle).to receive(:show_in_sections!).ordered.and_call_original

      described_class.new(bundle:, section_ids: []).perform
    end
  end
end
