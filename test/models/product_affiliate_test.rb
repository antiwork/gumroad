# frozen_string_literal: true

require "test_helper"

class ProductAffiliateTest < ActiveSupport::TestCase
  self.described_class = ProductAffiliate



  context_ ProductAffiliate do
  context_ "associations" do
      it { is_expected.to belong_to(:affiliate) }
      it { is_expected.to belong_to(:product).class_name("Link") }
    end

  context_ "validations" do
  context_ "when another record exists" do
  test "validates uniqueness of affiliate scoped to product" do
          existing = create(:product_affiliate)
          product_affiliate = build(:product_affiliate, affiliate: existing.affiliate, product: existing.product)
          expect(product_affiliate).not_to be_valid
        end
      end

  context_ "for a collaborator" do
        let(:collaborator) { create(:collaborator, apply_to_all_products: false) }

  test "validates presence of `affiliate_basis_points` if `apply_to_all_products` is not set" do
          product_affiliate = build(:product_affiliate, affiliate: collaborator, affiliate_basis_points: nil)
          expect(product_affiliate).not_to be_valid

          collaborator.update!(apply_to_all_products: true)
          product_affiliate = build(:product_affiliate, affiliate: collaborator, affiliate_basis_points: nil)
          expect(product_affiliate).to be_valid
        end

  test "validates `affiliate_basis_points` is in the correct range if present" do
          product_affiliate = build(:product_affiliate, affiliate: collaborator, affiliate_basis_points: 51_00)
          expect(product_affiliate).not_to be_valid

          product_affiliate.affiliate_basis_points = 50_00
          expect(product_affiliate).to be_valid

          product_affiliate.affiliate_basis_points = 0
          expect(product_affiliate).not_to be_valid
        end

  test "validates that the product has no other live collaborators" do
          product = create(:product)
          # ignores affiliates
          create(:product_affiliate, product:, affiliate: create(:user).global_affiliate)
          create(:direct_affiliate, products: [product])

          product_affiliate = create(:product_affiliate, affiliate: collaborator, product:)
          expect(product_affiliate).to be_valid

          new_collaborator = create(:collaborator)
          product_affiliate = build(:product_affiliate, affiliate: new_collaborator, product:)
          expect(product_affiliate).not_to be_valid
          collaborator.mark_deleted!
          expect(product_affiliate).to be_valid
        end
      end

  context_ "for a direct affiliate" do
  test "validates that the product is not a collab" do
          affiliate = create(:direct_affiliate)
          product = create(:product, :is_collab)
          product_affiliate = build(:product_affiliate, affiliate:, product:)
          expect(product_affiliate).not_to be_valid
          expect(product_affiliate.errors.full_messages).to eq ["Collab products cannot have affiliates"]
        end
      end
    end

  context_ "lifecycle hooks" do
  context_ "toggling product is_collab flag" do
  context_ "for a collaborator" do
          let!(:affiliate) { create(:collaborator) }

  test "enables the is_collab flag when a product affiiate is created, and disables any self service affiliate products and direct affiliates" do
            product = create(:product, is_collab: false)
            self_service_affiliate_product = create(:self_service_affiliate_product, seller: product.user, product: product, enabled: true)
            direct_affiliate = create(:direct_affiliate, seller: product.user, products: [product])

            expect do
              create(:product_affiliate, affiliate:, product:)
            end.to change { product.reload.is_collab }.from(false).to(true)
               .and change { self_service_affiliate_product.reload.enabled }.from(true).to(false)
               .and change { direct_affiliate.product_affiliates.count }.from(1).to(0)
          end

  test "disables the is_collab flag when a product affiliate is deleted" do
            product = create(:product, is_collab: true)
            product_affiliate = create(:product_affiliate, affiliate:, product:)

            expect do
              product_affiliate.destroy
            end.to change { product.reload.is_collab }.from(true).to(false)
          end
        end

  context_ "for another type of affiliate" do
          let!(:affiliate) { create(:direct_affiliate) }

  test "does not change the is_collab flag when a product affiiate is created" do
            product = create(:product, is_collab: false)

            expect do
              create(:product_affiliate, affiliate:, product:)
            end.not_to change { product.reload.is_collab }
          end

  test "does not change the is_collab flag when a product affiliate is deleted" do
            product = create(:product, is_collab: true)
            product_affiliate = build(:product_affiliate, affiliate:, product:)
            product_affiliate.save(validate: false) # bypass `product_is_not_a_collab` validation

            expect do
              product_affiliate.destroy
            end.not_to change { product.reload.is_collab }
          end
        end
      end
    end

  context_ "#affiliate_percentage" do
      let(:product_affiliate) { create(:product_affiliate, affiliate_basis_points:) }

  context_ "when affiliate_basis_point is nil" do
        let(:affiliate_basis_points) { nil }

  test "returns nil" do
          expect(product_affiliate.affiliate_percentage).to be_nil
        end
      end

  context_ "when affiliate_basis_point is set" do
        let(:affiliate_basis_points) { 500 }

  test "returns the correct affiliate percentage value" do
          expect(product_affiliate.affiliate_percentage).to eq(5)
        end
      end
    end
  end
end
