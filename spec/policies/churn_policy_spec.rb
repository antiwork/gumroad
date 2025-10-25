# frozen_string_literal: true

require "spec_helper"

describe ChurnPolicy do
  subject { described_class }

  let(:seller) { create(:named_seller) }
  let(:admin_user) { create(:user) }
  let(:marketing_user) { create(:user) }
  let(:support_user) { create(:user) }
  let(:accountant_user) { create(:user) }
  let(:regular_user) { create(:user) }
  let(:unauthorized_user) { create(:user) }
  let!(:subscription_product) { create(:subscription_product, user: seller) }

  before do
    create(:team_membership, user: admin_user, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_user, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_user, seller:, role: TeamMembership::ROLE_SUPPORT)
    create(:team_membership, user: accountant_user, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
  end

  permissions :show? do
    it "grants access to seller owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, :churn)
    end

    it "grants access to admin users" do
      seller_context = SellerContext.new(user: admin_user, seller:)
      expect(subject).to permit(seller_context, :churn)
    end

    it "grants access to marketing users" do
      seller_context = SellerContext.new(user: marketing_user, seller:)
      expect(subject).to permit(seller_context, :churn)
    end

    it "grants access to support users" do
      seller_context = SellerContext.new(user: support_user, seller:)
      expect(subject).to permit(seller_context, :churn)
    end

    it "grants access to accountant users" do
      seller_context = SellerContext.new(user: accountant_user, seller:)
      expect(subject).to permit(seller_context, :churn)
    end

    it "denies access to regular users without team membership" do
      seller_context = SellerContext.new(user: regular_user, seller:)
      expect(subject).not_to permit(seller_context, :churn)
    end

    it "denies access to unauthorized users" do
      seller_context = SellerContext.new(user: unauthorized_user, seller:)
      expect(subject).not_to permit(seller_context, :churn)
    end

    it "handles ActiveRecord::RecordNotFound gracefully" do
      allow_any_instance_of(User).to receive(:member_of?).and_raise(ActiveRecord::RecordNotFound)
      seller_context = SellerContext.new(user: admin_user, seller:)
      expect(subject).not_to permit(seller_context, :churn)
    end
  end

  describe "authorization scenarios" do
    it "allows admin users to view churn data" do
      seller_context = SellerContext.new(user: admin_user, seller:)
      policy = described_class.new(seller_context, :churn)
      expect(policy.show?).to be true
    end

    it "allows marketing users to view churn data" do
      seller_context = SellerContext.new(user: marketing_user, seller:)
      policy = described_class.new(seller_context, :churn)
      expect(policy.show?).to be true
    end

    it "allows support users to view churn data" do
      seller_context = SellerContext.new(user: support_user, seller:)
      policy = described_class.new(seller_context, :churn)
      expect(policy.show?).to be true
    end

    it "allows accountant users to view churn data" do
      seller_context = SellerContext.new(user: accountant_user, seller:)
      policy = described_class.new(seller_context, :churn)
      expect(policy.show?).to be true
    end

    it "denies regular users access to churn data" do
      seller_context = SellerContext.new(user: regular_user, seller:)
      policy = described_class.new(seller_context, :churn)
      expect(policy.show?).to be false
    end
  end

  context "when seller has no subscription products" do
    let(:seller_without_subscriptions) { create(:user, username: "nosubsseller", email: "nosubs@example.com") }
    let(:admin_for_non_subscription_seller) { create(:user, username: "adminnosubs", email: "adminnosubs@example.com") }

    before do
      create(:team_membership, user: admin_for_non_subscription_seller, seller: seller_without_subscriptions, role: TeamMembership::ROLE_ADMIN)
    end

    it "denies access even to admin users" do
      seller_context = SellerContext.new(user: admin_for_non_subscription_seller, seller: seller_without_subscriptions)
      policy = described_class.new(seller_context, :churn)
      expect(policy.show?).to be false
    end

    it "denies access in authorization scenario" do
      seller_context = SellerContext.new(user: admin_for_non_subscription_seller, seller: seller_without_subscriptions)
      policy = described_class.new(seller_context, :churn)
      expect(policy.show?).to be false
    end
  end
end
