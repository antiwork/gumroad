# frozen_string_literal: true

require "test_helper"

class UtmLinkPolicyTest < ActiveSupport::TestCase
  self.described_class = UtmLinkPolicy



  context_ UtmLinkPolicy do
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

      Feature.activate_user(:utm_links, seller)
    end

    permissions :index? do
  test "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end
    end

    permissions :new? do
  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "denies access to other roles" do
        [accountant_for_seller, support_for_seller].each do |user|
          seller_context = SellerContext.new(user:, seller:)
          expect(subject).not_to permit(seller_context, :utm_link)
        end
      end
    end

    permissions :create? do
  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "denies access to other roles" do
        [accountant_for_seller, support_for_seller].each do |user|
          seller_context = SellerContext.new(user:, seller:)
          expect(subject).not_to permit(seller_context, :utm_link)
        end
      end
    end

    permissions :edit? do
  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "denies access to other roles" do
        [accountant_for_seller, support_for_seller].each do |user|
          seller_context = SellerContext.new(user:, seller:)
          expect(subject).not_to permit(seller_context, :utm_link)
        end
      end
    end

    permissions :update? do
  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "denies access to other roles" do
        [accountant_for_seller, support_for_seller].each do |user|
          seller_context = SellerContext.new(user:, seller:)
          expect(subject).not_to permit(seller_context, :utm_link)
        end
      end
    end

    permissions :destroy? do
  test "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, :utm_link)
      end

  test "denies access to other roles" do
        [accountant_for_seller, support_for_seller].each do |user|
          seller_context = SellerContext.new(user:, seller:)
          expect(subject).not_to permit(seller_context, :utm_link)
        end
      end
    end
  end
end
