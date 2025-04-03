# frozen_string_literal: true

require "spec_helper"

describe CollaboratorPresenter do
  describe "#new_collaborator_props" do
    let(:seller) { create(:user) }
    let!(:visible_product) { create(:product, user: seller) }
    let!(:archived_product) { create(:product, user: seller, archived: true) }
    let!(:deleted_product) { create(:product, user: seller, deleted_at: 1.day.ago) }
    let!(:product_with_affiliates) { create(:product, user: seller).tap { |product| create(:direct_affiliate, products: [product]) } }
    let!(:ineligible_product) { create(:product, user: seller).tap { |product| create(:collaborator, products: [product]) } }
    let!(:product_with_global_affiliate) do
      create(:product, user: seller, purchase_disabled_at: Time.current).tap do |product|
        create(:product_affiliate, product:, affiliate: create(:user).global_affiliate)
      end
    end
    let!(:product_with_deleted_collaborator) do
      create(:product, user: seller).tap do |product|
        create(:collaborator, seller:, products: [product], deleted_at: 1.day.ago)
      end
    end

    it "returns the seller's visible and not archived products" do
      expect(described_class.new(seller:).new_collaborator_props).to eq(
        {
          products: [
            { id: visible_product.external_id, name: visible_product.name, published: true, has_another_collaborator: false, has_affiliates: false, enabled: false, percent_commission: nil, dont_show_as_co_creator: false },
            { id: product_with_affiliates.external_id, name: product_with_affiliates.name, published: true, has_another_collaborator: false, has_affiliates: true, enabled: false, percent_commission: nil, dont_show_as_co_creator: false },
            { id: ineligible_product.external_id, name: ineligible_product.name, published: true, has_another_collaborator: true, has_affiliates: false, enabled: false, percent_commission: nil, dont_show_as_co_creator: false },
            { id: product_with_global_affiliate.external_id, name: product_with_global_affiliate.name, published: false, has_another_collaborator: false, has_affiliates: false, enabled: false, percent_commission: nil, dont_show_as_co_creator: false },
            { id: product_with_deleted_collaborator.external_id, name: product_with_deleted_collaborator.name, published: true, has_another_collaborator: false, has_affiliates: false, enabled: false, percent_commission: nil, dont_show_as_co_creator: false },
          ],
          collaborators_disabled_reason: nil,
        }
      )
    end
  end

  describe "#collaborator_props" do
    let(:seller) { create(:user) }
    let(:visible_product) { create(:product, user: seller) }
    let!(:archived_product) { create(:product, user: seller, archived: true) }
    let!(:deleted_product) { create(:product, user: seller, deleted_at: 1.day.ago) }
    let!(:ineligible_product) { create(:product, user: seller).tap { |product| create(:collaborator, products: [product]) } }
    let(:collaborator) { create(:collaborator, seller:, products: [visible_product]) }

    it "returns the collaborator and its products" do
      props = described_class.new(seller:, collaborator:).collaborator_props

      expect(props.except(:products)).to match(collaborator.as_json)
      expect(props[:products]).to match_array([{ id: visible_product.external_id, name: visible_product.name, percent_commission: nil }])
    end
  end

  describe "#edit_collaborator_props" do
    let(:seller) { create(:user) }
    let(:visible_product) { create(:product, user: seller) }
    let!(:archived_product) { create(:product, user: seller, archived: true) }
    let!(:deleted_product) { create(:product, user: seller, deleted_at: 1.day.ago) }
    let!(:ineligible_product) { create(:product, user: seller).tap { |product| create(:collaborator, products: [product]) } }
    let!(:collaborator) { create(:collaborator, seller:, products: [visible_product]) }

    it "returns the collaborator and eligible products" do
      props = described_class.new(seller:, collaborator:).edit_collaborator_props

      expect(props.except(:products, :collaborators_disabled_reason)).to match(collaborator.as_json)
      expect(props[:products]).to match_array([
                                                { id: visible_product.external_id, name: visible_product.name, published: true, has_another_collaborator: false, has_affiliates: false, enabled: true, percent_commission: nil, dont_show_as_co_creator: false },
                                                { id: ineligible_product.external_id, name: ineligible_product.name, published: true, has_another_collaborator: true, has_affiliates: false, enabled: false, percent_commission: nil, dont_show_as_co_creator: false },
                                              ])
      expect(props[:collaborators_disabled_reason]).to eq(nil)
    end

    context "when the seller has a Brazilian Stripe Connect account" do
      before do
        allow(seller).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
      end

      it "returns the appropriate disabled reason" do
        props = described_class.new(seller:, collaborator:).edit_collaborator_props
        expect(props[:collaborators_disabled_reason]).to eq("Collaborators with Brazilian Stripe accounts are not supported.")
      end
    end
  end
end
