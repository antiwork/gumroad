# frozen_string_literal: true

require "test_helper"

class SubscriptionPolicyTest < ActiveSupport::TestCase
  self.described_class = SubscriptionPolicy



  context_ SubscriptionPolicy do
    subject { described_class }

    let(:accountant_for_seller) { create(:user) }
    let(:admin_for_seller) { create(:user) }
    let(:marketing_for_seller) { create(:user) }
    let(:support_for_seller) { create(:user) }
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }

    before do
      create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
      create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
      create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
      create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
    end

  context_ "with subscription belongs to seller's product" do
      let(:subscription) { create(:subscription, link: product) }

      permissions :unsubscribe_by_seller? do
  test "grants access to owner" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).to permit(seller_context, subscription)
        end

  test "denies access to accountant" do
          seller_context = SellerContext.new(user: accountant_for_seller, seller:)
          expect(subject).not_to permit(seller_context, subscription)
        end

  test "grants access to admin" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).to permit(seller_context, subscription)
        end

  test "denies access to marketing" do
          seller_context = SellerContext.new(user: marketing_for_seller, seller:)
          expect(subject).not_to permit(seller_context, subscription)
        end

  test "grants access to support" do
          seller_context = SellerContext.new(user: support_for_seller, seller:)
          expect(subject).to permit(seller_context, subscription)
        end
      end
    end

  context_ "with subscription belongs to other seller's product" do
      let(:subscription) { create(:subscription) }

      permissions :unsubscribe_by_seller? do
  test "denies access" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).not_to permit(seller_context, subscription)
        end
      end
    end
  end
end
