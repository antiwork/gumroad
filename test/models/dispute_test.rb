# frozen_string_literal: true

require "test_helper"

class DisputeTest < ActiveSupport::TestCase
  self.described_class = Dispute



  context_ Dispute do
  context_ "creation" do
  test "sets seller when creating from a purchase" do
        dispute = create(:dispute)
        expect(dispute.seller).to eq(dispute.purchase.seller)
      end

  test "sets seller when creating from a charge" do
        dispute = create(:dispute, purchase: nil, charge: create(:charge))
        expect(dispute.seller).to eq(dispute.charge.seller)
      end

  test "can't be created without a purchase or a charge" do
        dispute = build(:dispute, purchase: nil)
        expect(dispute).not_to be_valid
        expect(dispute.errors[:base][0]).to eq("A Disputable object must be provided.")
      end

  test "can't be created with both purchase and charge" do
        dispute = build(:dispute, charge: create(:charge), purchase: create(:purchase))
        expect(dispute).not_to be_valid
        expect(dispute.errors[:base][0]).to eq("Only one Disputable object must be provided.")
      end
    end

  context_ "#disputable" do
  test "returns the associated purchase if dispute belongs to a purchase" do
        disputed_purchase = create(:purchase)
        expect(create(:dispute, purchase: disputed_purchase).disputable).to eq(disputed_purchase)
      end

  test "returns the associated charge if dispute belongs to a charge" do
        disputed_charge = create(:charge)
        expect(create(:dispute_on_charge, charge: disputed_charge).disputable).to eq(disputed_charge)
      end
    end
  end
end
