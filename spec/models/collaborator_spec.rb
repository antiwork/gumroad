# frozen_string_literal: true

require "spec_helper"

describe Collaborator do
  describe "associations" do
    it { is_expected.to belong_to(:seller) }
  end

  describe "validations" do
    it { is_expected.to validate_numericality_of(:affiliate_basis_points).is_greater_than_or_equal_to(1_00).is_less_than_or_equal_to(50_00).allow_nil }

    context "when another record exists" do
      before { create(:collaborator) }

      it { is_expected.to validate_uniqueness_of(:seller_id).scoped_to(:affiliate_user_id, :deleted_at) }
    end

    describe "affiliate_basis_points presence" do
      it "requires affiliate_basis_points to be present if apply_to_all_products is set" do
        collaborator = build(:collaborator, apply_to_all_products: true, affiliate_basis_points: nil)
        expect(collaborator).not_to be_valid
        expect(collaborator.errors.full_messages).to eq ["Affiliate basis points can't be blank"]

        collaborator.affiliate_basis_points = 30_00
        expect(collaborator).to be_valid
      end

      it "does not require affiliate_basis_points to be present if apply_to_all_products is not set" do
        collaborator = build(:collaborator, apply_to_all_products: false, affiliate_basis_points: nil)
        expect(collaborator).to be_valid
      end
    end

    describe "collaborator_does_not_require_approval" do
      context "when affiliate_user has changed" do
        let(:collaborator) { build(:collaborator, affiliate_user: create(:user, require_collab_request_approval: true)) }

        it "requires the affiliate user to allow collaborator requests without approval" do
          expect(collaborator.save).to eq false
          expect(collaborator.errors.full_messages).to match_array ["You cannot add this user as a collaborator"]
        end
      end

      context "when affiliate_user has not changed" do
        let(:collaborator) { create(:collaborator) }
        before { collaborator.affiliate_user.update!(require_collab_request_approval: true) }

        it "does not require the affiliate user to allow collaborator requests without approval" do
          expect(collaborator.update(affiliate_basis_points: 25_00)).to eq true
        end
      end
    end

    describe "eligible_for_stripe_payments" do
      let(:seller) { create(:user) }
      let(:affiliate_user) { create(:user) }
      let(:collaborator) { build(:collaborator, seller:, affiliate_user:) }

      context "when affiliate user has a Brazilian Stripe Connect account" do
        before do
          allow(affiliate_user).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
          allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
        end

        it "is invalid" do
          expect(collaborator).not_to be_valid
          expect(collaborator.errors[:base]).to include(
            "This user cannot be added as a collaborator because they use a Brazilian Stripe account."
          )
        end
      end

      context "when seller has a Brazilian Stripe Connect account" do
        before do
          allow(affiliate_user).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
          allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
        end

        it "is invalid" do
          expect(collaborator).not_to be_valid
          expect(collaborator.errors[:base]).to include(
            "You cannot add a collaborator because you are using a Brazilian Stripe account."
          )
        end
      end

      context "when neither user has a Brazilian Stripe Connect account" do
        before do
          allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
          allow(affiliate_user).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
        end

        it "is valid" do
          expect(collaborator).to be_valid
        end
      end
    end
  end

  describe "scopes" do
    describe ".invitation_accepted and .invitation_pending" do
      it "returns collaborators without invitations" do
        accepted_collaborator = create(:collaborator)
        pending_collaborator = create(:collaborator, :with_pending_invitation)

        expect(Collaborator.invitation_accepted).to contain_exactly(accepted_collaborator)
        expect(Collaborator.invitation_pending).to contain_exactly(pending_collaborator)
      end
    end
  end

  describe "#invitation_accepted?" do
    it "returns true when the collaborator has no invitation" do
      collaborator = create(:collaborator)
      collaborator.create_collaborator_invitation!
      expect(collaborator.invitation_accepted?).to be false

      collaborator.collaborator_invitation.destroy!
      expect(collaborator.reload.invitation_accepted?).to be true
    end
  end

  describe "#as_json" do
    it "returns a hash of attributes" do
      product = create(:product)
      collaborator = create(:collaborator, seller: product.user, affiliate_basis_points: 25_00, dont_show_as_co_creator: true)
      collaborator.product_affiliates.create!(product:, affiliate_basis_points: 50_00)

      expect(collaborator.as_json).to match(
        id: collaborator.external_id,
        email: collaborator.affiliate_user.email,
        name: collaborator.affiliate_user.display_name(prefer_email_over_default_username: true),
        apply_to_all_products: collaborator.apply_to_all_products?,
        avatar_url: collaborator.affiliate_user.avatar_url,
        percent_commission: 25,
        setup_incomplete: false,
        dont_show_as_co_creator: true,
        invitation_accepted: true,
      )
    end

    it "includes the invitation_accepted status" do
      collaborator = create(:collaborator)
      create(:collaborator_invitation, collaborator: collaborator)

      expect(collaborator.as_json[:invitation_accepted]).to be false
    end
  end

  describe "#mark_deleted!" do
    it "disables the is_collab flag on all associated products" do
      products = create_list(:product, 2, is_collab: true)
      collaborator = create(:collaborator, products:)

      expect do
        collaborator.mark_deleted!
      end.to change { collaborator.reload.deleted? }.from(false).to(true)
         .and change { products.first.reload.is_collab }.from(true).to(false)
         .and change { products.last.reload.is_collab }.from(true).to(false)
    end
  end

  describe "#basis_points" do
    let(:collaborator) { create(:collaborator, affiliate_basis_points: 10_00) }
    let(:product_affiliate) { create(:product_affiliate, affiliate: collaborator, affiliate_basis_points: product_affiliate_basis_points) }

    context "when no product_id is provided" do
      let(:product_affiliate_basis_points) { nil }

      it "returns the collaborator's basis points" do
        expect(collaborator.basis_points).to eq 10_00
      end
    end

    context "when product_id is provided" do
      context "and the product affiliate commission is set" do
        let(:product_affiliate_basis_points) { 20_00 }

        it "returns the product affiliate's basis points" do
          expect(collaborator.basis_points(product_id: product_affiliate.link_id)).to eq 20_00
        end
      end

      context "and product affiliate commission is not set" do
        let(:product_affiliate_basis_points) { nil }

        it "returns the collaborator's basis points" do
          expect(collaborator.basis_points(product_id: product_affiliate.link_id)).to eq 10_00
        end
      end
    end
  end

  describe "#show_as_co_creator_for_product?" do
    let(:product) { create(:product) }

    context "when apply_to_all_products is true" do
      let(:collaborator) { create(:collaborator) }
      let!(:product_affiliate) { create(:product_affiliate, affiliate: collaborator, product:, dont_show_as_co_creator: true) }

      it "returns true if dont_show_as_co_creator is false, false otherwise" do
        expect(collaborator.show_as_co_creator_for_product?(product)).to eq true

        collaborator.dont_show_as_co_creator = true
        expect(collaborator.show_as_co_creator_for_product?(product)).to eq false
      end
    end

    context "when apply_to_all_products is false" do
      let(:collaborator) { create(:collaborator, apply_to_all_products: false, dont_show_as_co_creator: true) }
      let!(:product_affiliate) { create(:product_affiliate, affiliate: collaborator, product:, dont_show_as_co_creator: false) }


      it "returns true if the product_affiliate's dont_show_as_co_creator is false, false otherwise" do
        expect(collaborator.show_as_co_creator_for_product?(product)).to eq true

        product_affiliate.update!(dont_show_as_co_creator: true)
        expect(collaborator.show_as_co_creator_for_product?(product)).to eq false
      end
    end
  end
end
