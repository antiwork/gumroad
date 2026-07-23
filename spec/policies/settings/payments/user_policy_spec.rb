# frozen_string_literal: true

require "spec_helper"

describe Settings::Payments::UserPolicy do
  subject { described_class }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:seller) { create(:named_seller) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :show? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end
  end

  # Payout configuration actions: allowed for the owner and for team members
  # with the admin role (per Sahil's directive, 2026-07-20), forbidden for
  # every other role.
  permissions :update?, :set_country?, :remove_credit_card?, :paypal_connect?,
              :stripe_connect?, :remediation?, :verify_stripe_remediation?,
              :opt_in_to_au_backtax_collection? do
    context "with owner as seller" do
      let(:seller_context) { SellerContext.new(user: seller, seller:) }

      it "grants access to owner" do
        expect(subject).to permit(seller_context, seller)
      end

      it "denies access to owner when record is other user" do
        expect(subject).not_to permit(seller_context, create(:user))
      end
    end

    context "with admin for seller" do
      let(:seller_context) { SellerContext.new(user: admin_for_seller, seller:) }

      it "grants access to admin" do
        expect(subject).to permit(seller_context, seller)
      end

      it "denies access to admin when record is other user" do
        expect(subject).not_to permit(seller_context, create(:user))
      end
    end

    context "with marketing for seller" do
      let(:seller_context) { SellerContext.new(user: marketing_for_seller, seller:) }

      it "denies access to marketing" do
        expect(subject).not_to permit(seller_context, seller)
      end
    end

    context "with accountant for seller" do
      let(:seller_context) { SellerContext.new(user: accountant_for_seller, seller:) }

      it "denies access to accountant" do
        expect(subject).not_to permit(seller_context, seller)
      end
    end

    context "with support for seller" do
      let(:seller_context) { SellerContext.new(user: support_for_seller, seller:) }

      it "denies access to support" do
        expect(subject).not_to permit(seller_context, seller)
      end
    end
  end

  # Identity verification (KYC) actions submit the account owner's personal
  # identity documents. A team admin cannot legitimately verify someone
  # else's identity, so these remain owner-only.
  permissions :verify_document?, :verify_identity? do
    context "with owner as seller" do
      let(:seller_context) { SellerContext.new(user: seller, seller:) }

      it "grants access to owner" do
        expect(subject).to permit(seller_context, seller)
      end

      it "denies access to owner when record is other user" do
        expect(subject).not_to permit(seller_context, create(:user))
      end
    end

    context "with admin for seller" do
      let(:seller_context) { SellerContext.new(user: admin_for_seller, seller:) }

      it "denies access to admin" do
        expect(subject).not_to permit(seller_context, seller)
      end
    end

    context "with marketing for seller" do
      let(:seller_context) { SellerContext.new(user: marketing_for_seller, seller:) }

      it "denies access to marketing" do
        expect(subject).not_to permit(seller_context, seller)
      end
    end

    context "with accountant for seller" do
      let(:seller_context) { SellerContext.new(user: accountant_for_seller, seller:) }

      it "denies access to accountant" do
        expect(subject).not_to permit(seller_context, seller)
      end
    end

    context "with support for seller" do
      let(:seller_context) { SellerContext.new(user: support_for_seller, seller:) }

      it "denies access to support" do
        expect(subject).not_to permit(seller_context, seller)
      end
    end
  end
end
