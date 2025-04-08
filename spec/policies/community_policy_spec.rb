# frozen_string_literal: true

require "spec_helper"

describe CommunityPolicy do
  subject { described_class }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:seller) { create(:named_seller) }
  let(:buyer) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let!(:community) { create(:community, seller: seller, resource: product) }
  let(:other_product) { create(:product, community_chat_enabled: true) }
  let!(:other_community) { create(:community, seller: other_product.user, resource: other_product) }
  let!(:purchase) { create(:purchase, purchaser: buyer, link: other_product) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :index? do
    context "when user has accessible communities" do
      before do
        Feature.activate_user(:communities, seller)
        Feature.activate_user(:communities, other_product.user)
      end

      it "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, Community)
      end

      it "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "grants access to buyer with purchased product" do
        seller_context = SellerContext.new(user: buyer, seller: other_product.user)
        expect(subject).to permit(seller_context, Community)
      end

      it "denies access to seller who has at least one product but no active communities" do
        another_seller = create(:user)
        create(:product, user: another_seller)
        Feature.activate_user(:communities, another_seller)
        seller_context = SellerContext.new(user: another_seller, seller:)

        expect(subject).not_to permit(seller_context, Community)
      end
    end

    context "when user has no accessible communities" do
      before do
        Feature.deactivate_user(:communities, seller)
        Feature.deactivate_user(:communities, other_product.user)
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Community)
      end

      it "denies access to buyer with purchased product" do
        purchase
        seller_context = SellerContext.new(user: buyer, seller: other_product.user)
        expect(subject).not_to permit(seller_context, Community)
      end
    end
  end

  permissions :show? do
    context "when user has access to the community" do
      before do
        Feature.activate_user(:communities, seller)
        Feature.activate_user(:communities, other_product.user)
      end

      context "when user is a seller" do
        it "grants access to own community" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).to permit(seller_context, community)
        end

        it "denies access to other seller's community" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).not_to permit(seller_context, other_community)
        end
      end

      context "when user is a buyer" do
        it "grants access to community of purchased product" do
          purchase
          seller_context = SellerContext.new(user: buyer, seller:)
          expect(subject).to permit(seller_context, other_community)
        end

        it "denies access to community of unpurchased product" do
          seller_context = SellerContext.new(user: buyer, seller:)
          expect(subject).not_to permit(seller_context, community)
        end
      end

      context "when user is a team member" do
        it "denies access to seller's community" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).not_to permit(seller_context, community)
        end

        it "denies access to other seller's community" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).not_to permit(seller_context, other_community)
        end
      end
    end

    context "when user has no access to the community" do
      before do
        Feature.deactivate_user(:communities, seller)
        Feature.deactivate_user(:communities, other_product.user)
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end

      it "denies access to buyer" do
        purchase
        seller_context = SellerContext.new(user: buyer, seller:)
        expect(subject).not_to permit(seller_context, other_community)
      end

      it "denies access to team members" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end
    end

    context "when community's resource is deleted" do
      before do
        Feature.activate_user(:communities, seller)
        product.mark_deleted!
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end

      it "denies access to team members" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end
    end

    context "when community chat is disabled" do
      before do
        Feature.activate_user(:communities, seller)
        product.update!(community_chat_enabled: false)
      end

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end

      it "denies access to team members" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, community)
      end
    end
  end
end
