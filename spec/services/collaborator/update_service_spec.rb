# frozen_string_literal: true

require "spec_helper"

describe Collaborator::UpdateService do
  describe "#process" do
    let(:seller) { create(:user) }
    let(:product1) { create(:product, user: seller) }
    let(:product2) { create(:product, user: seller) }
    let(:product3) { create(:product, user: seller) }
    let(:apply_to_all_products) { false }
    let(:collaborator) { create(:collaborator, apply_to_all_products:, seller:, affiliate_basis_points: 40_00) }
    let(:enabled_products) { [product2, product3] }

    before do
      create(:product_affiliate, affiliate: collaborator, product: product1, affiliate_basis_points: 30_00)
      create(:product_affiliate, affiliate: collaborator, product: product2, affiliate_basis_points: 30_00)
    end

    let(:params) do
      {
        apply_to_all_products: true,
        percent_commission: 50,
        products: enabled_products.map { { id: _1.external_id } }
      }
    end

    context "with apply_to_all_products true" do
      it "updates the collaborator and its products, setting the existing percent commission on newly enabled products" do
        expect do
          result = described_class.new(seller:, collaborator_id: collaborator.external_id, params:).process

          expect(result).to eq({ success: true })
        end.to have_enqueued_mail(AffiliateMailer, :collaborator_update).with { collaborator.id }

        collaborator.reload
        expect(collaborator.affiliate_basis_points).to eq 50_00
        expect(collaborator.apply_to_all_products).to eq true
        expect(collaborator.products).to match_array enabled_products
        expect(collaborator.product_affiliates.find_by(product: product2).affiliate_basis_points).to eq 50_00
        expect(collaborator.product_affiliates.find_by(product: product3).affiliate_basis_points).to eq 50_00
      end
    end

    context "with apply_to_all_products false" do
      let(:apply_to_all_products) { true }
      let(:params) do
        {
          apply_to_all_products: false,
          percent_commission: nil,
          products: [
            { id: product2.external_id, percent_commission: 25 },
            { id: product3.external_id, percent_commission: 50 }
          ]
        }
      end

      it "uses the product percent_commission for the specific product" do
        result = described_class.new(seller:, collaborator_id: collaborator.external_id, params:).process

        expect(result).to eq({ success: true })
        collaborator.reload
        expect(collaborator.affiliate_basis_points).to eq 40_00 # does not set default commission to nil
        expect(collaborator.apply_to_all_products).to eq false
        expect(collaborator.products).to match_array enabled_products
        expect(collaborator.product_affiliates.find_by(product: product2).affiliate_basis_points).to eq 25_00
        expect(collaborator.product_affiliates.find_by(product: product3).affiliate_basis_points).to eq 50_00
      end
    end

    it "raises an error if the collaborator does not belong to the seller" do
      expect do
        described_class.new(seller:, collaborator_id: create(:collaborator).external_id, params:).process
      end.to raise_error ActiveRecord::RecordNotFound
    end

    it "raises an error if product cannot be found" do
      params[:products] = [{ id: SecureRandom.hex }]
      expect do
        described_class.new(seller:, collaborator_id: collaborator.external_id, params:).process
      end.to raise_error ActiveRecord::RecordNotFound
    end

    context "when one product in the requested set is invalid" do
      before do
        params[:products] = [{ id: product2.external_id }, { id: SecureRandom.hex }]
      end

      it "leaves the existing revenue share untouched" do
        expect do
          described_class.new(seller:, collaborator_id: collaborator.external_id, params:).process
        end.to raise_error ActiveRecord::RecordNotFound

        collaborator.reload
        expect(collaborator.products).to match_array [product1, product2]
        expect(collaborator.product_affiliates.find_by(product: product1).affiliate_basis_points).to eq 30_00
        expect(collaborator.product_affiliates.find_by(product: product2).affiliate_basis_points).to eq 30_00
        expect(product1.reload.is_collab).to eq true
      end

      it "does not email the collaborator about a change that did not happen" do
        expect do
          described_class.new(seller:, collaborator_id: collaborator.external_id, params:).process
        rescue ActiveRecord::RecordNotFound
          nil
        end.not_to have_enqueued_mail(AffiliateMailer, :collaborator_update)
      end
    end

    # The rollback itself, rather than the pre-flight resolve: here every product id is real, so the
    # destroys and the re-assignment do run, and only `collaborator.save` refuses. Without the
    # transaction the de-selected row would already be gone by then.
    context "when the collaborator itself fails validation" do
      before do
        params[:percent_commission] = Collaborator::MAX_PERCENT_COMMISSION + 10
      end

      it "returns the invalid collaborator and leaves the existing revenue share untouched" do
        result = nil

        expect do
          result = described_class.new(seller:, collaborator_id: collaborator.external_id, params:).process
        end.not_to have_enqueued_mail(AffiliateMailer, :collaborator_update)

        expect(result[:success]).to eq false
        expect(result[:collaborator].errors[:base]).to be_present

        collaborator.reload
        expect(collaborator.affiliate_basis_points).to eq 40_00
        expect(collaborator.apply_to_all_products).to eq false
        expect(collaborator.products).to match_array [product1, product2]
        expect(collaborator.product_affiliates.find_by(product: product1).affiliate_basis_points).to eq 30_00
        expect(collaborator.product_affiliates.find_by(product: product2).affiliate_basis_points).to eq 30_00
        expect(product1.reload.is_collab).to eq true
      end
    end

    context "when a product belongs to another seller" do
      let(:other_sellers_product) { create(:product) }

      before do
        params[:products] = [{ id: product2.external_id }, { id: other_sellers_product.external_id }]
      end

      it "leaves the existing revenue share untouched" do
        expect do
          described_class.new(seller:, collaborator_id: collaborator.external_id, params:).process
        end.to raise_error ActiveRecord::RecordNotFound

        collaborator.reload
        expect(collaborator.products).to match_array [product1, product2]
      end
    end
  end
end
