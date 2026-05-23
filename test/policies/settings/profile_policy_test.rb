# frozen_string_literal: true

require "test_helper"

class SettingsProfilePolicyTest < ActiveSupport::TestCase
  self.described_class = Settings::ProfilePolicy



  context_ Settings::ProfilePolicy do
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
  test "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end

  test "grants access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end

  test "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end
    end

    permissions :update? do
  test "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end

  test "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, seller)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end

  test "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, seller)
      end
    end

    permissions :update_username?, :manage_social_connections? do
  test "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, seller)
      end

  test "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, seller)
      end

  test "denies access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, seller)
      end

  test "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, seller)
      end

  test "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, seller)
      end
    end

  context_ "#permitted_attributes" do
  test "allows owner to update the username" do
        policy = described_class.new(SellerContext.new(user: seller, seller:), seller)
        expect(policy.permitted_attributes).to include(a_hash_including(user: a_collection_including(:username)))
      end

  test "does not allow accountant to update the username" do
        policy = described_class.new(SellerContext.new(user: accountant_for_seller, seller:), seller)
        expect(policy.permitted_attributes).not_to include(a_hash_including(user: a_collection_including(:username)))
      end

  test "does not allow admin to update the username" do
        policy = described_class.new(SellerContext.new(user: admin_for_seller, seller:), seller)
        expect(policy.permitted_attributes).not_to include(a_hash_including(user: a_collection_including(:username)))
      end

  test "does not allow marketing to update the username" do
        policy = described_class.new(SellerContext.new(user: marketing_for_seller, seller:), seller)
        expect(policy.permitted_attributes).not_to include(a_hash_including(user: a_collection_including(:username)))
      end

  test "does not allow support to update the username" do
        policy = described_class.new(SellerContext.new(user: support_for_seller, seller:), seller)
        expect(policy.permitted_attributes).not_to include(a_hash_including(user: a_collection_including(:username)))
      end
    end
  end
end
