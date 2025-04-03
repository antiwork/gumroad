# frozen_string_literal: true

require "spec_helper"

describe Dispute do
  describe "creation" do
    it "sets seller when creating from a purchase" do
      dispute = create(:dispute)
      expect(dispute.seller).to eq(dispute.purchase.seller)
    end

    it "sets seller when creating from a charge" do
      dispute = create(:dispute, purchase: nil, charge: create(:charge))
      expect(dispute.seller).to eq(dispute.charge.seller)
    end

    it "can't be created without a purchase or a charge" do
      dispute = build(:dispute, purchase: nil)
      expect(dispute).not_to be_valid
      expect(dispute.errors[:base][0]).to eq("A Disputable object must be provided.")
    end

    it "can't be created with both purchase and charge" do
      dispute = build(:dispute, charge: create(:charge), purchase: create(:purchase))
      expect(dispute).not_to be_valid
      expect(dispute.errors[:base][0]).to eq("Only one Disputable object must be provided.")
    end
  end

  describe "#disputable" do
    it "returns the associated purchase if dispute belongs to a purchase" do
      disputed_purchase = create(:purchase)
      expect(create(:dispute, purchase: disputed_purchase).disputable).to eq(disputed_purchase)
    end

    it "returns the associated charge if dispute belongs to a charge" do
      disputed_charge = create(:charge)
      expect(create(:dispute_on_charge, charge: disputed_charge).disputable).to eq(disputed_charge)
    end
  end
end
