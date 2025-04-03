# frozen_string_literal: true

require "spec_helper"

describe Products::Archived::LinkPolicy do
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

  permissions :index? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, :archived)
    end

    it "grants access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).to permit(seller_context, :archived)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, :archived)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, :archived)
    end

    it "grants access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to permit(seller_context, :archived)
    end
  end

  permissions :create? do
    let(:product) { create(:product, user: seller, archived: false) }

    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, product)
    end

    context "when product is archived" do
      before do
        product.update(archived: true)
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, product)
      end
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, product)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, product)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, product)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, product)
    end
  end

  permissions :destroy? do
    let(:product) { create(:product, user: seller, archived: true) }

    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, product)
    end

    context "when product is not archived" do
      before do
        product.update!(archived: false)
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, product)
      end
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, product)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, product)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, product)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, product)
    end
  end
end
