# frozen_string_literal: true

require "test_helper"

class AudiencePurchasePolicyTest < ActiveSupport::TestCase
  self.described_class = Audience::PurchasePolicy



  context_ Audience::PurchasePolicy do
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
  test "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, Purchase)
      end

  test "grants access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).to permit(seller_context, Purchase)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, Purchase)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, Purchase)
      end

  test "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, Purchase)
      end
    end

    permissions :update?, :refund?, :change_can_contact?, :cancel_preorder_by_seller?, :mark_as_shipped?, :manage_license? do
  test "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, Follower)
      end

  test "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Purchase)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, Follower)
      end

  test "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Follower)
      end

  test "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, Purchase)
      end
    end

    permissions :revoke_access? do
      let(:purchase) { create(:purchase) }
      let(:seller_context) { SellerContext.new(user: seller, seller:) }

  test "grants access to owner" do
        expect(subject).to permit(seller_context, purchase)
      end

  test "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Purchase)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, purchase)
      end

  test "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, purchase)
      end

  test "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, purchase)
      end

  context_ "when access has been revoked" do
        before do
          purchase.update!(is_access_revoked: true)
        end

  test "denies access" do
          expect(subject).not_to permit(seller_context, purchase)
        end
      end

  context_ "when purchase is refunded" do
        before do
          purchase.update!(stripe_refunded: true)
        end

  test "denies access" do
          expect(subject).not_to permit(seller_context, purchase)
        end
      end

  context_ "when product is physical" do
        let(:purchase) { create(:physical_purchase, link: create(:physical_product)) }

  test "denies access" do
          expect(subject).not_to permit(seller_context, purchase)
        end
      end

  context_ "when purchase is subscription" do
        let(:purchase) { create(:membership_purchase) }

  test "denies access" do
          expect(subject).not_to permit(seller_context, purchase)
        end
      end
    end

    permissions :undo_revoke_access? do
      let(:purchase) { create(:purchase, is_access_revoked: true) }
      let(:seller_context) { SellerContext.new(user: seller, seller:) }

  test "grants access to owner" do
        expect(subject).to permit(seller_context, purchase)
      end

  test "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Purchase)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, purchase)
      end

  test "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, purchase)
      end

  test "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, Purchase)
      end

  context_ "when access has not been revoked" do
        before do
          purchase.update!(is_access_revoked: false)
        end

  test "denies access" do
          expect(subject).not_to permit(seller_context, purchase)
        end
      end
    end
  end
end
