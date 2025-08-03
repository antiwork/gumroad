# frozen_string_literal: true

require "spec_helper"
require "shared_examples/policy_examples"

describe AffiliateInvitationPolicy do
  subject { described_class }

  let(:seller) { create(:named_seller) }
  let(:affiliate_user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:affiliate) { create(:direct_affiliate, seller: seller, affiliate_user: affiliate_user) }
  let(:affiliate_invitation) { create(:affiliate_invitation, affiliate: affiliate) }

  permissions :accept?, :decline? do
    context "when the current user is the affiliate user" do
      it "grants access" do
        context = SellerContext.new(user: affiliate_user, seller: seller)
        expect(subject).to permit(context, affiliate_invitation)
      end
    end

    context "when the current user is not the affiliate user" do
      it "denies access" do
        context = SellerContext.new(user: other_user, seller: seller)
        expect(subject).not_to permit(context, affiliate_invitation)
      end
    end

    context "when the current user is the seller" do
      it "denies access" do
        context = SellerContext.new(user: seller, seller: seller)
        expect(subject).not_to permit(context, affiliate_invitation)
      end
    end
  end
end
