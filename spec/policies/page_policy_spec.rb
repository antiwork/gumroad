# frozen_string_literal: true

require "spec_helper"

describe PagePolicy do
  subject { described_class }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:seller) { create(:named_seller) }
  let(:other_user) { create(:user) }
  let(:page) { create(:page, user: seller) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  shared_examples "admin/marketing only" do |action|
    permissions action do
      it "grants access to owner" do
        expect(subject).to permit(SellerContext.new(user: seller, seller:), record)
      end

      it "grants access to admin" do
        expect(subject).to permit(SellerContext.new(user: admin_for_seller, seller:), record)
      end

      it "grants access to marketing" do
        expect(subject).to permit(SellerContext.new(user: marketing_for_seller, seller:), record)
      end

      it "denies accountant" do
        expect(subject).not_to permit(SellerContext.new(user: accountant_for_seller, seller:), record)
      end

      it "denies support" do
        expect(subject).not_to permit(SellerContext.new(user: support_for_seller, seller:), record)
      end

      it "denies users with no team membership" do
        expect(subject).not_to permit(SellerContext.new(user: other_user, seller:), record)
      end
    end
  end

  context "for the Page class (index/templates/new/create)" do
    let(:record) { Page }
    include_examples "admin/marketing only", :index?
    include_examples "admin/marketing only", :templates?
    include_examples "admin/marketing only", :new?
    include_examples "admin/marketing only", :create?
  end

  context "for a Page instance (edit/update/destroy/latest_version)" do
    let(:record) { page }
    include_examples "admin/marketing only", :edit?
    include_examples "admin/marketing only", :update?
    include_examples "admin/marketing only", :destroy?
    include_examples "admin/marketing only", :latest_version?
  end
end
