# frozen_string_literal: true

require "spec_helper"

describe Purchase do
  describe "#tax_location_valid?" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    def purchase_for(country:, ip_country:, card_country: nil)
      build(:purchase, link: product, seller:, country:, ip_country:, card_country:)
    end

    context "when the buyer's IP resolves to the seller's own country" do
      before { create(:user_compliance_info, user: seller, country: "Canada") }

      it "trusts the buyer's selection even when no card country was recorded" do
        purchase = purchase_for(country: "United States", ip_country: "Canada")

        expect(purchase.send(:tax_location_valid?)).to eq(true)
        expect(purchase.error_code).to be_nil
      end

      it "does not extend that trust to a buyer who is somewhere else" do
        purchase = purchase_for(country: "United States", ip_country: "Germany")

        expect(purchase.send(:tax_location_valid?)).to eq(false)
        expect(purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
      end
    end

    it "still trusts a buyer whose selected country matches their IP country" do
      create(:user_compliance_info, user: seller, country: "Canada")

      purchase = purchase_for(country: "Germany", ip_country: "Germany")

      expect(purchase.send(:tax_location_valid?)).to eq(true)
    end
  end
end
