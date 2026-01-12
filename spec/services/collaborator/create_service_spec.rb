# frozen_string_literal: true

require "spec_helper"

describe Collaborator::CreateService do
  describe "#process" do
    let(:seller) { create(:user) }
    let(:collaborating_user) { create(:user) }
    let(:products) { create_list(:product, 3, user: seller) }
    let!(:enabled_products) { products.first(2) }
    let(:params) do
      {
        email: collaborating_user.email,
        apply_to_all_products: true,
        percent_commission: 30,
        products: enabled_products.map { { id: _1.external_id } }
      }
    end



    context "with 'apply_to_all_products' enabled" do
      it "creates a collaborator" do
        expect do
          result = described_class.new(seller:, params:).process
          expect(result).to eq({ success: true })
        end.to change { seller.collaborators.count }.from(0).to(1)
           .and change { ProductAffiliate.count }.from(0).to(2)

        collaborator = seller.collaborators.find_by(affiliate_user_id: collaborating_user.id)
        expect(collaborator.apply_to_all_products).to eq true
        expect(collaborator.affiliate_percentage).to eq 30

        enabled_products.each do |product|
          pa = collaborator.product_affiliates.find_by(product:)
          expect(pa).to be_present
          expect(pa.affiliate_percentage).to eq 30
        end
      end
    end

    context "with 'apply_to_all_products' disabled" do
      let(:product1) { enabled_products.first }
      let(:product2) { enabled_products.last }
      let(:params) do
        {
          email: collaborating_user.email,
          apply_to_all_products: false,
          percent_commission: nil,
          products: [
            { id: product1.external_id, percent_commission: 25 },
            { id: product2.external_id, percent_commission: 50 },
          ],
        }
      end

      it "creates a collaborator" do
        expect do
          result = described_class.new(seller:, params:).process
          expect(result).to eq({ success: true })
        end.to change { seller.collaborators.count }.from(0).to(1)
           .and change { ProductAffiliate.count }.from(0).to(2)

        collaborator = seller.collaborators.find_by(affiliate_user_id: collaborating_user.id)
        expect(collaborator.apply_to_all_products).to eq false
        expect(collaborator.affiliate_percentage).to be_nil

        pa = collaborator.product_affiliates.find_by(product: product1)
        expect(pa).to be_present
        expect(pa.affiliate_percentage).to eq 25

        pa = collaborator.product_affiliates.find_by(product: product2)
        expect(pa).to be_present
        expect(pa.affiliate_percentage).to eq 50
      end

      it "returns an error when commission is missing" do
        params[:products] = [
          { id: product1.external_id, percent_commission: 50 },
          { id: product2.external_id },
        ]

        expect do
          result = described_class.new(seller:, params:).process
          expect(result[:success]).to eq false
          expect(result[:collaborator].errors.to_hash[:base]).to eq(["Product affiliates affiliate basis points must be greater than or equal to 100"])
        end.to change { seller.collaborators.count }.by(0)
           .and change { ProductAffiliate.count }.by(0)
      end
    end

    it "creates a collaborator if the user is associated with a deleted collaborator" do
      create(:collaborator, seller:, affiliate_user: collaborating_user, deleted_at: Time.current)
      expect do
        result = described_class.new(seller:, params:).process
        expect(result).to eq({ success: true })
      end.to change { seller.collaborators.count }.from(1).to(2)
         .and change { ProductAffiliate.count }.from(0).to(2)
    end

    it "returns an error if the user cannot be found" do
      params[:email] = "foo@example.com"
      result = described_class.new(seller:, params:).process
      expect(result[:success]).to eq false
      expect(result[:collaborator].errors.to_hash).to eq({ base: ["The email address isn't associated with a Gumroad account."] })
    end

    it "returns an error if the user is already a collaborator, regardless of invitation status" do
      collaborator = create(
        :collaborator,
        :with_pending_invitation,
        seller:,
        affiliate_user: collaborating_user
      )

      result = described_class.new(seller:, params:).process
      expect(result[:success]).to eq false
      expect(result[:collaborator].errors.to_hash).to eq({ base: ["The user is already a collaborator"] })

      collaborator.collaborator_invitation.destroy!

      result = described_class.new(seller:, params:).process
      expect(result[:success]).to eq false
      expect(result[:collaborator].errors.to_hash).to eq({ base: ["The user is already a collaborator"] })
    end

    it "returns an error if product cannot be found" do
      params[:products] = [{ id: "abc123" }]
      result = described_class.new(seller:, params:).process
      expect(result[:success]).to eq false
      expect(result[:collaborator].errors.to_hash).to eq({ base: ["Product not found"] })
    end

    it "returns an error if the user requires approval of any collaborator requests" do
      collaborating_user.update!(require_collab_request_approval: true)
      result = described_class.new(seller:, params:).process
      expect(result[:success]).to eq false
      expect(result[:collaborator].errors.to_hash).to eq({ base: ["You cannot add this user as a collaborator"] })
    end

    it "returns an error if the seller is using a Brazilian Stripe Connect account" do
      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: seller, country: "BR")
      seller.update!(check_merchant_account_is_linked: true)
      expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      result = described_class.new(seller:, params:).process
      expect(result[:success]).to eq false
      expect(result[:collaborator].errors.to_hash).to eq({ base: ["You cannot add a collaborator because you are using a Brazilian Stripe account."] })
    end

    it "returns an error if the collaborating user is using a Brazilian Stripe Connect account" do
      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: collaborating_user, country: "BR")
      collaborating_user.update!(check_merchant_account_is_linked: true)
      expect(collaborating_user.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      result = described_class.new(seller:, params:).process
      expect(result[:success]).to eq false
      expect(result[:collaborator].errors.to_hash).to eq({ base: ["This user cannot be added as a collaborator because they use a Brazilian Stripe account."] })
    end

    describe "email notifications" do
      it "sends a collaborator invitation email when a collaborator is invited" do
        expect do
          result = described_class.new(seller:, params:).process
          expect(result).to eq({ success: true })
        end
          .to have_enqueued_mail(AffiliateMailer, :collaborator_invited).with { Collaborator.last.id }
      end

      it "sends a collaborator creation email when a collaborator is added" do
        create(:collaborator, seller: collaborating_user, affiliate_user: seller)

        expect do
          result = described_class.new(seller:, params:).process
          expect(result).to eq({ success: true })
        end
          .to have_enqueued_mail(AffiliateMailer, :collaborator_creation).with { Collaborator.last.id }
      end
    end

    describe "invitations" do
      context "when reciprocal collaboration exists" do
        let!(:reciprocal_collaboration) do
          create(:collaborator, seller: collaborating_user, affiliate_user: seller)
        end

        it "does not build a collaborator invitation" do
          result = described_class.new(seller:, params:).process
          expect(result).to eq({ success: true })

          collaborator = seller.collaborators.find_by(affiliate_user: collaborating_user)
          expect(collaborator.collaborator_invitation).to be_nil
        end

        it "builds a collaborator invitation when invitation not accepted" do
          create(:collaborator_invitation, collaborator: reciprocal_collaboration)

          result = described_class.new(seller:, params:).process
          expect(result).to eq({ success: true })

          collaborator = seller.collaborators.find_by(affiliate_user: collaborating_user)
          expect(collaborator.collaborator_invitation).to be_present
        end

        it "builds a collaborator invitation when reciprocal collaboration is soft deleted" do
          reciprocal_collaboration.mark_deleted!

          result = described_class.new(seller:, params:).process
          expect(result).to eq({ success: true })

          collaborator = seller.collaborators.find_by(affiliate_user: collaborating_user)
          expect(collaborator.collaborator_invitation).to be_present
        end
      end

      it "builds a collaborator invitation when reciprocal collaboration does not exist" do
        result = described_class.new(seller:, params:).process
        expect(result).to eq({ success: true })

        collaborator = seller.collaborators.find_by(affiliate_user: collaborating_user)
        expect(collaborator.collaborator_invitation).to be_present
      end
    end
  end
end
