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

    describe "buyer-currency fields" do
      let(:seller) { create(:user, google_analytics_id: "G-ABC123") }
      let(:product) { create(:product, user: seller) }
      let(:purchase) { create(:purchase, link: product, displayed_price_cents: 10_00) }
      # The charge factory's default merchant account collides with the shared Gumroad
      # managed-account uniqueness validation, so give the presentment's charge its own.
      let(:charge_presentment) do
        create(:charge_presentment, charge: create(:charge, merchant_account: create(:merchant_account, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")))
      end

      it "omits them for a canonical USD sale" do
        event = described_class.new(purchase).props[:purchase_event]

        expect(event).not_to have_key(:buyer_presentment_currency)
        expect(event).not_to have_key(:buyer_presentment_value)
      end

      it "includes the buyer currency and charged total for a presentment sale" do
        create(:purchase_presentment, purchase:, charge_presentment:,
                                      presentment_currency: Currency::CAD,
                                      presentment_price_cents: 12_00,
                                      presentment_tip_cents: 0,
                                      presentment_seller_tax_cents: 0,
                                      presentment_gumroad_tax_cents: 1_50,
                                      presentment_shipping_cents: 0,
                                      presentment_total_cents: 13_50)

        event = described_class.new(purchase.reload).props[:purchase_event]

        expect(event[:buyer_presentment_currency]).to eq("CAD")
        expect(event[:buyer_presentment_value]).to eq(13.5)
        # Canonical fields keep their existing meaning so current reports are unaffected.
        expect(event[:currency]).to eq(purchase.displayed_price_currency_type.to_s)
        expect(event[:value]).to eq(10_00)
      end

      it "does not divide zero-decimal currencies by 100" do
        create(:purchase_presentment, purchase:, charge_presentment:,
                                      presentment_currency: Currency::JPY,
                                      presentment_price_cents: 1_500,
                                      presentment_tip_cents: 0,
                                      presentment_seller_tax_cents: 0,
                                      presentment_gumroad_tax_cents: 0,
                                      presentment_shipping_cents: 0,
                                      presentment_total_cents: 1_500)

        event = described_class.new(purchase.reload).props[:purchase_event]

        expect(event[:buyer_presentment_currency]).to eq("JPY")
        expect(event[:buyer_presentment_value]).to eq(1_500)
      end
    end
  end
end
