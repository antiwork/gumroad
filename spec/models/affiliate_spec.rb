# frozen_string_literal: true

require "spec_helper"

describe Affiliate do
  describe "scopes" do
    describe "affiliate types" do
      let!(:direct_affiliate) { create(:direct_affiliate) }
      let!(:confirmed_collaborator) { create(:collaborator) }
      let!(:pending_collaborator) { create(:collaborator, :with_pending_invitation) }

      it "returns all collaborators" do
        expect(Affiliate.direct_affiliates).to contain_exactly(direct_affiliate)
        expect(Affiliate.global_affiliates).to match_array GlobalAffiliate.all
        expect(Affiliate.direct_or_global_affiliates).to match_array([direct_affiliate] + GlobalAffiliate.all)

        expect(Affiliate.pending_collaborators).to contain_exactly(pending_collaborator)
        expect(Affiliate.confirmed_collaborators).to contain_exactly(confirmed_collaborator)
        expect(Affiliate.pending_or_confirmed_collaborators).to contain_exactly(confirmed_collaborator, pending_collaborator)
      end
    end

    describe ".for_product" do
      let(:product) { create(:product) }
      let(:seller) { product.user }
      let!(:direct_affiliate) { create(:direct_affiliate, seller:, products: [product]) }

      before do
        create(:direct_affiliate, seller:, products: [create(:product, user: seller)])
        create(:direct_affiliate)
      end

      it "includes only direct affiliates for the product if the seller does not participate in discover" do
        allow(product).to receive(:recommendable?).and_return(false)
        affiliates = Affiliate.for_product(product)
        expect(affiliates).to match_array [direct_affiliate]
      end

      it "includes global affiliates if the seller participates in discover" do
        allow(product).to receive(:recommendable?).and_return(true)
        affiliates = Affiliate.for_product(product)
        expect(affiliates).to match_array GlobalAffiliate.all + [direct_affiliate]
      end

      it "includes only direct affiliates if the product is not recommendable" do
        allow(product).to receive(:recommendable?).and_return(false)
        affiliates = Affiliate.for_product(product)
        expect(affiliates).to match_array [direct_affiliate]
      end
    end

    describe ".valid_for_product" do
      let(:product) { create(:product) }
      let(:seller) { product.user }
      let!(:direct_affiliate) { create(:direct_affiliate, seller:, products: [product]) }
      let(:suspended_user) { create(:tos_user) }

      before do
        create(:direct_affiliate)
        create(:direct_affiliate, seller:, products: [create(:product, user: seller)])
        create(:direct_affiliate, seller:, products: [product], deleted_at: 1.day.ago)
        create(:direct_affiliate, seller:, products: [product], affiliate_user: suspended_user)
      end

      it "includes only live direct affiliates for the product if the seller does not participate in discover" do
        allow(product).to receive(:recommendable?).and_return(false)
        affiliates = Affiliate.valid_for_product(product)
        expect(affiliates).to match_array [direct_affiliate]
      end

      it "includes only live direct and global affiliates if the seller participates in discover" do
        allow(product).to receive(:recommendable?).and_return(true)
        affiliates = Affiliate.valid_for_product(product)
        expect(affiliates).to match_array GlobalAffiliate.where.not(affiliate_user: suspended_user) + [direct_affiliate]
      end
    end
  end

  describe "validations" do
    context "uniqueness of affiliate user scoped to seller" do
      it "invalidates another alive affiliate with the same scope" do
        existing = create(:direct_affiliate)
        affiliate = build(:direct_affiliate, affiliate_user: existing.affiliate_user, seller: existing.seller)
        expect(affiliate).not_to be_valid
      end

      it "validates the affiliate for the same user with a different seller" do
        existing = create(:direct_affiliate)
        affiliate = build(:direct_affiliate, affiliate_user: existing.affiliate_user)
        expect(affiliate).to be_valid
      end

      it "validates the affiliate with the same scope when the existing affiliate is deleted" do
        existing = create(:direct_affiliate, deleted_at: 1.day.ago)
        affiliate = build(:direct_affiliate, affiliate_user: existing.affiliate_user, seller: existing.seller)
        expect(affiliate).to be_valid
      end

      it "validates the affiliate with the same scope when the existing affiliate is deleted" do
        existing = create(:direct_affiliate, deleted_at: 1.day.ago)
        affiliate = build(:direct_affiliate, affiliate_user: existing.affiliate_user, seller: existing.seller)
        expect(affiliate).to be_valid
      end
    end
  end

  describe "#affiliate_info" do
    let(:affiliate_user) { create(:affiliate_user, username: "creator") }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, apply_to_all_products: true) }

    it "returns info about the affiliate" do
      expect(affiliate.affiliate_info).to eq(
        {
          email: affiliate_user.email,
          destination_url: affiliate.destination_url,
          affiliate_user_name: "creator",
          fee_percent: 3,
          id: affiliate.external_id,
        }
      )
    end
  end

  describe "#global?" do
    it "returns true for a global affiliate, false for other affiliate types" do
      expect(GlobalAffiliate.new.global?).to eq true
      expect(build(:direct_affiliate).global?).to eq false
      expect(build(:collaborator).global?).to eq false
    end
  end

  describe "#collaborator?" do
    it "returns true for a collaborator, false for other affiliate types" do
      expect(build(:collaborator).collaborator?).to eq true
      expect(GlobalAffiliate.new.collaborator?).to eq false
      expect(build(:direct_affiliate).collaborator?).to eq false
    end
  end

  describe "#total_cents_earned" do
    let(:affiliate) { create(:direct_affiliate, affiliate_basis_points: 1000) }

    it "sums the affiliate credits earned for all successful, paid purchases" do
      create(:purchase, affiliate:, purchase_state: "successful", price_cents: 100)
      create(:purchase, affiliate:, purchase_state: "failed", price_cents: 150)
      create(:purchase, affiliate:, purchase_state: "successful", price_cents: 0).update!(affiliate_credit_cents: 8) # should not have affiliate credits > 0 - just for testing purposes
      create(:purchase, affiliate:, purchase_state: "successful", price_cents: 1399)

      expect(affiliate.total_cents_earned).to eq 113
    end

    it "excludes refunded or chargedback purchases" do
      create(:purchase, affiliate:, purchase_state: "successful", price_cents: 100, chargeback_date: 1.day.ago)
      create(:purchase, affiliate:, purchase_state: "successful", price_cents: 150, stripe_refunded: true)

      expect(affiliate.total_cents_earned).to eq 0
    end
  end

  describe "#total_cents_earned_formatted" do
    it "returns the formatted amount earned" do
      affiliate = create(:direct_affiliate, affiliate_basis_points: 1000)
      create(:purchase, affiliate:, purchase_state: "successful", price_cents: 100)
      create(:purchase, affiliate:, purchase_state: "successful", price_cents: 1399)

      expect(affiliate.total_cents_earned_formatted).to eq "$1.13"
    end
  end

  describe "#enabled_products" do
    let(:affiliate_user) { create(:affiliate_user, username: "creator") }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, apply_to_all_products: true) }
    let!(:product1) { create(:product, name: "Gumbot bits", user: affiliate.seller) }
    let(:product2) { create(:product, name: "ChatGPT4 prompts", user: affiliate.seller) }
    let(:product3) { create(:product, name: "Beautiful banner", user: affiliate.seller) }

    before do
      create(:product_affiliate, affiliate:, product: product1, affiliate_basis_points: affiliate.affiliate_basis_points)
      create(:product_affiliate, affiliate:, product: product2, affiliate_basis_points: 45_00)
      create(:product_affiliate, affiliate:, product: product3, affiliate_basis_points: 23_00)

      create(:product, name: "Unaffiliated product we ignore", user: affiliate.seller)
      create(:product, name: "Unaffiliated product we ignore 2", user: affiliate.seller)
    end

    it "only returns affiliated products for an affiliate" do
      expect(affiliate.enabled_products).to eq(
        [
          {
            id: product1.external_id_numeric,
            name: "Gumbot bits",
            fee_percent: 3,
            referral_url: affiliate.referral_url_for_product(product1),
            destination_url: nil,
          },
          {
            id: product2.external_id_numeric,
            name: "ChatGPT4 prompts",
            fee_percent: 45,
            referral_url: affiliate.referral_url_for_product(product2),
            destination_url: nil,
          },
          {
            id: product3.external_id_numeric,
            name: "Beautiful banner",
            fee_percent: 23,
            referral_url: affiliate.referral_url_for_product(product3),
            destination_url: nil,
          }
        ]
      )
    end
  end

  describe "#basis_points" do
    let(:affiliate) { create(:user).global_affiliate }

    it "returns the global affiliate's basis points" do
      expect(affiliate.basis_points).to eq 10_00
    end
  end

  describe "#affiliate_percentage" do
    it "returns the affiliate_basis_points as a percentage" do
      affiliate = build(:direct_affiliate, affiliate_basis_points: 25_00)
      expect(affiliate.affiliate_percentage).to eq 25
    end

    it "returns nil if affiliate_basis_points is nil" do
      affiliate = build(:collaborator, affiliate_basis_points: nil) # currently only collaborators can have nil affiliate_basis_points
      expect(affiliate.affiliate_percentage).to be_nil
    end
  end

  describe "#eligible_for_credit?" do
    let(:affiliate_user) { create(:affiliate_user, username: "creator") }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, apply_to_all_products: true) }

    it "returns false if affiliate is deleted" do
      expect(affiliate.eligible_for_credit?).to be true

      affiliate.update!(deleted_at: Time.current)

      expect(affiliate.eligible_for_credit?).to be false
    end

    it "returns false if affiliated user account is suspended" do
      expect(affiliate.eligible_for_credit?).to be true

      affiliate_user.flag_for_tos_violation!(author_id: User.last.id, bulk: true)
      affiliate_user.suspend_for_tos_violation!(author_id: User.last.id, bulk: true)

      expect(affiliate.eligible_for_credit?).to be false
    end

    it "returns false if affiliated user is using a Brazilian Stripe Connect account" do
      expect(affiliate.eligible_for_credit?).to be true

      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: affiliate_user, country: "BR")
      affiliate_user.update!(check_merchant_account_is_linked: true)
      expect(affiliate_user.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      expect(affiliate.eligible_for_credit?).to be false
    end
  end
end
