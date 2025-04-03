# frozen_string_literal: true

require "spec_helper"

describe CollaboratorsPresenter do
  describe "#index_props" do
    let(:seller) { create(:user) }
    let(:product_1) { create(:product, user: seller) }
    let(:product_2) { create(:product, user: seller) }

    let!(:deleted_collaborator) { create(:collaborator, seller:, products: [product_1], deleted_at: 1.day.ago) }
    let!(:confirmed_collaborator) { create(:collaborator, seller:, products: [product_1]) }
    let!(:pending_collaborator) { create(:collaborator, :with_pending_invitation, seller:, products: [product_2]) }



    it "returns the seller's live collaborators" do
      props = described_class.new(seller:).index_props

      expect(props).to match(
        collaborators: [confirmed_collaborator, pending_collaborator].map do
          CollaboratorPresenter.new(seller:, collaborator: _1).collaborator_props
        end,
        collaborators_disabled_reason: nil,
        has_incoming_collaborators: false,
      )
    end

    it "returns collaborators supported as false if using a Brazilian Stripe Connect account" do
      brazilian_stripe_account = create(:merchant_account_stripe_connect, user: seller, country: "BR")
      seller.update!(check_merchant_account_is_linked: true)
      expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

      props = described_class.new(seller:).index_props

      expect(props[:collaborators_disabled_reason]).to eq "Collaborators with Brazilian Stripe accounts are not supported."
    end

    it "returns if the seller has any incoming collaborations" do
      props = described_class.new(seller: pending_collaborator.affiliate_user).index_props
      expect(props[:has_incoming_collaborators]).to eq true

      pending_collaborator.collaborator_invitation.accept!
      props = described_class.new(seller: pending_collaborator.affiliate_user).index_props
      expect(props[:has_incoming_collaborators]).to eq true

      pending_collaborator.mark_deleted!
      props = described_class.new(seller: pending_collaborator.affiliate_user).index_props
      expect(props[:has_incoming_collaborators]).to eq false
    end
  end
end
