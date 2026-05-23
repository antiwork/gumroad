# frozen_string_literal: true

require "test_helper"

class CallPolicyTest < ActiveSupport::TestCase
  self.described_class = CallPolicy



  context_ CallPolicy do
    subject { described_class }

    let(:accountant_for_seller) { create(:user) }
    let(:admin_for_seller) { create(:user) }
    let(:marketing_for_seller) { create(:user) }
    let(:support_for_seller) { create(:user) }
    let(:call) { create(:call) }
    let!(:seller) { call.purchase.seller }

    before do
      create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
      create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
      create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
      create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
    end

    permissions :update? do
  context_ "when the call belongs to the seller" do
        before do
          allow(call.purchase).to receive(:seller).and_return(seller)
        end

  test "grants access to seller" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).to permit(seller_context, call)
        end

  test "denies access to accountant" do
          seller_context = SellerContext.new(user: accountant_for_seller, seller:)
          expect(subject).not_to permit(seller_context, call)
        end

  test "grants access to admin" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).to permit(seller_context, call)
        end

  test "denies access to marketing" do
          seller_context = SellerContext.new(user: marketing_for_seller, seller:)
          expect(subject).not_to permit(seller_context, call)
        end

  test "grants access to support" do
          seller_context = SellerContext.new(user: support_for_seller, seller:)
          expect(subject).to permit(seller_context, call)
        end
      end

  context_ "when the call belongs to another seller" do
        let!(:other_call) { create(:call) }

  test "denies access to seller" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).not_to permit(seller_context, other_call)
        end

  test "denies access to accountant" do
          seller_context = SellerContext.new(user: accountant_for_seller, seller:)
          expect(subject).not_to permit(seller_context, other_call)
        end

  test "denies access to admin" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).not_to permit(seller_context, other_call)
        end

  test "denies access to marketing" do
          seller_context = SellerContext.new(user: marketing_for_seller, seller:)
          expect(subject).not_to permit(seller_context, other_call)
        end

  test "denies access to support" do
          seller_context = SellerContext.new(user: support_for_seller, seller:)
          expect(subject).not_to permit(seller_context, other_call)
        end
      end
    end
  end
end
