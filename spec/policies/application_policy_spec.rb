# frozen_string_literal: true

require "spec_helper"

describe ApplicationPolicy do
  describe "#initialize" do
    let(:user) { create(:user) }
    let(:seller) { create(:named_seller) }

    it "assigns accessors" do
      context = SellerContext.new(user:, seller:)
      policy = described_class.new(context, :record)

      expect(policy.user).to eq(user)
      expect(policy.seller).to eq(seller)
      expect(policy.record).to eq(:record)
    end

    it "raises when user is nil" do
      context = SellerContext.new(user: nil, seller:)
      expect do
        described_class.new(context, :record)
      end.to raise_error(Pundit::NotAuthorizedError).with_message "must be logged in"
    end
  end
end
