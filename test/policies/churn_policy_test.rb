# frozen_string_literal: true

require "test_helper"

class ChurnPolicyTest < ActiveSupport::TestCase
  self.described_class = ChurnPolicy



  context_ ChurnPolicy do
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
      Feature.activate_user(:churn_analytics_enabled, seller)
    end

    permissions :show? do
  test "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, :churn)
      end

  test "grants access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).to permit(seller_context, :churn)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, :churn)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, :churn)
      end

  test "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, :churn)
      end

  context_ "when churn_analytics_enabled feature is inactive" do
        before do
          Feature.deactivate_user(:churn_analytics_enabled, seller)
        end

  test "denies access" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).not_to permit(seller_context, :churn)
        end
      end
    end
  end
end
