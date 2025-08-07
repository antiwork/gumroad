# frozen_string_literal: true

require "spec_helper"

describe UserPolicy do
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

  permissions :deactivate? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).to_not permit(seller_context, seller)
    end

    it "denies access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to_not permit(seller_context, seller)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to_not permit(seller_context, seller)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end
  end

  permissions :generate_product_details_with_ai? do
    context "when ai_product_generation feature is inactive" do
      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, seller)
      end
    end

    context "when ai_product_generation feature is active" do
      before do
        Feature.activate_user(:ai_product_generation, seller)
      end

      context "when seller is not confirmed" do
        before do
          seller.update!(confirmed_at: nil)
        end

        it "denies access" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).not_to permit(seller_context, seller)
        end
      end

      context "when seller is confirmed" do
        before do
          seller.confirm
        end

        context "when seller is suspended" do
          before do
            seller.update!(user_risk_state: :suspended_for_fraud)
          end

          it "denies access" do
            seller_context = SellerContext.new(user: seller, seller:)
            expect(subject).not_to permit(seller_context, seller)
          end
        end

        context "when seller has insufficient sales" do
          before do
            product = create(:product, user: seller)
            create(:purchase, seller: seller, link: product, purchase_state: :successful, price_cents: 5_000)
            allow(seller).to receive(:sales_cents_total).and_return(5_000)
          end

          it "denies access when sales are below $100" do
            seller_context = SellerContext.new(user: seller, seller:)
            expect(subject).not_to permit(seller_context, seller)
          end
        end

        context "when seller has sufficient sales but no completed payouts" do
          before do
            product = create(:product, user: seller)
            create(:purchase, seller: seller, link: product, purchase_state: :successful, price_cents: 15_000)
            allow(seller).to receive(:sales_cents_total).and_return(15_000)
            # No payment created, so has_completed_payouts? returns false
          end

          it "denies access when seller has not completed payouts" do
            seller_context = SellerContext.new(user: seller, seller:)
            expect(subject).not_to permit(seller_context, seller)
          end
        end

        context "when seller meets all requirements" do
          before do
            product = create(:product, user: seller)
            create(:purchase, seller: seller, link: product, purchase_state: :successful, price_cents: 15_000)
            create(:payment_completed, user: seller)
            allow(seller).to receive(:sales_cents_total).and_return(15_000)
          end

          it "grants access to owner" do
            seller_context = SellerContext.new(user: seller, seller:)
            expect(subject).to permit(seller_context, seller)
          end
        end
      end
    end
  end
end
