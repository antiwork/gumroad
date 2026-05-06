# frozen_string_literal: true

require "spec_helper"

describe FirstProductStarterPolicy do
  subject { described_class }

  let(:seller) { create(:user) }
  let(:context) { SellerContext.new(user: seller, seller: seller) }

  permissions :options?, :draft? do
    it "denies when the flag is off" do
      expect(subject).not_to permit(context, :first_product_starter)
    end

    it "permits when the flag is on and the seller is eligible" do
      Feature.activate_user(:first_product_starter, seller)
      seller.confirm
      expect(subject).to permit(context, :first_product_starter)
    end

    it "denies when the seller already has a visible product" do
      Feature.activate_user(:first_product_starter, seller)
      seller.confirm
      create(:product, user: seller, draft: false)
      expect(subject).not_to permit(context, :first_product_starter)
    end
  end
end
