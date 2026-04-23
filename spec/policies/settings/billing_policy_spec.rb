# frozen_string_literal: true

require "spec_helper"

describe Settings::BillingPolicy do
  subject { described_class }

  let(:owner) { create(:user) }
  let(:other_user) { create(:user) }

  permissions :show?, :update? do
    it "grants access when the viewer is the seller themselves" do
      context = SellerContext.new(user: owner, seller: owner)
      expect(subject).to permit(context, nil)
    end

    it "denies access when the viewer is a different user on the seller account" do
      context = SellerContext.new(user: other_user, seller: owner)
      expect(subject).not_to permit(context, nil)
    end
  end
end
