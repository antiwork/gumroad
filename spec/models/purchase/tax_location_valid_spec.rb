# frozen_string_literal: true

require "spec_helper"

describe Purchase do
  describe "#tax_location_valid?" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    before { create(:user_compliance_info, user: seller, country: "Canada") }

    def purchase_for(country:, ip_country:, card_country: nil)
      build(:purchase, link: product, seller:, country:, ip_country:, card_country:)
    end

    it "rejects a buyer in the seller's country who selects another country without card evidence" do
      purchase = purchase_for(country: "United States", ip_country: "Canada")

      expect(purchase.send(:tax_location_valid?)).to eq(false)
      expect(purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
    end

    it "rejects a buyer whose IP and card both match the seller's country but who selects another country" do
      purchase = purchase_for(country: "United States", ip_country: "Canada", card_country: "CA")

      expect(purchase.send(:tax_location_valid?)).to eq(false)
      expect(purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
    end

    it "accepts a selected country that matches the card country" do
      purchase = purchase_for(country: "United States", ip_country: "Canada", card_country: "US")

      expect(purchase.send(:tax_location_valid?)).to eq(true)
    end

    it "accepts a selected country that matches the IP country" do
      purchase = purchase_for(country: "Germany", ip_country: "Germany")

      expect(purchase.send(:tax_location_valid?)).to eq(true)
    end
  end
end
