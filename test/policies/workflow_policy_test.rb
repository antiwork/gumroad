# frozen_string_literal: true

require "test_helper"

class WorkflowPolicyTest < ActiveSupport::TestCase
  self.described_class = WorkflowPolicy



  context_ WorkflowPolicy do
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
        expect(subject).to permit(seller_context, Workflow)
      end

  test "grants access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).to permit(seller_context, Workflow)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, Workflow)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, Workflow)
      end

  test "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, Workflow)
      end
    end

    permissions :create?, :new?, :edit?, :update?, :create_post_and_rule?, :create_and_publish_post_and_rule?, :delete?, :destroy?, :save_installments? do
  test "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, Workflow)
      end

  test "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Workflow)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, Workflow)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, Workflow)
      end

  test "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, Workflow)
      end
    end
  end
end
