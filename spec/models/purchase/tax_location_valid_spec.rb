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

    context "when paid with a wallet that recorded no card country" do
      it "accepts a taxable wallet country that differs from a taxable IP country" do
        purchase = purchase_for(country: "France", ip_country: "Portugal")
        purchase.wallet_payment = true

        expect(purchase.send(:tax_location_valid?)).to eq(true)
      end

      it "still rejects the same mismatch without a wallet" do
        purchase = purchase_for(country: "France", ip_country: "Portugal")

        expect(purchase.send(:tax_location_valid?)).to eq(false)
      end

      it "still rejects a non-taxable wallet country that differs from a taxable IP country" do
        purchase = purchase_for(country: "Morocco", ip_country: "Portugal")
        purchase.wallet_payment = true

        expect(purchase.send(:tax_location_valid?)).to eq(false)
      end

      it "still rejects when a card country was recorded and does not match" do
        purchase = purchase_for(country: "France", ip_country: "Portugal", card_country: "ES")
        purchase.wallet_payment = true

        expect(purchase.send(:tax_location_valid?)).to eq(false)
      end
    end

    it "accepts a selected country that matches the IP country" do
      purchase = purchase_for(country: "Germany", ip_country: "Germany")

      expect(purchase.send(:tax_location_valid?)).to eq(true)
    end

    context "when the IP country is unknown and the seller has no compliance country" do
      let(:seller) { create(:user) }

      before { seller.alive_user_compliance_info&.mark_deleted! }

      it "rejects a selected country that differs from the card country" do
        purchase = purchase_for(country: "United States", ip_country: nil, card_country: "FR")

        expect(seller.compliance_country_code).to be_nil
        expect(purchase.send(:tax_location_valid?)).to eq(false)
        expect(purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
      end

      it "accepts a selected country that matches the card country" do
        purchase = purchase_for(country: "France", ip_country: nil, card_country: "FR")

        expect(purchase.send(:tax_location_valid?)).to eq(true)
      end
    end
  end
end
