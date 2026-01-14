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
        has_incoming_collaborators: false,
      )
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
