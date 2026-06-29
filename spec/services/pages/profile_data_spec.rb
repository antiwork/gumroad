# frozen_string_literal: true

require "spec_helper"

describe Pages::ProfileData do
  describe ".build" do
    let(:seller) { create(:user) }

    context "when the seller has no saved profile row" do
      before do
        SellerProfile.where(seller_id: seller.id).delete_all
        seller.reload
      end

      it "returns an empty pages list without raising" do
        expect(Pages::ProfileData.build(seller)[:pages]).to eq([])
      end

      it "does not build a seller_profile on the seller as a side effect" do
        Pages::ProfileData.build(seller)

        expect(seller.association(:seller_profile)).not_to be_loaded
        expect(SellerProfile.exists?(seller_id: seller.id)).to be(false)
      end
    end

    context "when the seller has profile tabs" do
      before do
        seller.seller_profile.json_data["tabs"] = [{ "name" => "Shop", "sections" => [] }, { "name" => "", "sections" => [] }]
        seller.seller_profile.save!
      end

      it "returns only the named tabs" do
        expect(Pages::ProfileData.build(seller.reload)[:pages]).to eq([{ name: "Shop" }])
      end
    end
  end
end
