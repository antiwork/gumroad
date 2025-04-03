# frozen_string_literal: true

require "spec_helper"

describe Workflow::AbandonedCartProducts do
  include Rails.application.routes.url_helpers

  describe "#abandoned_cart_products" do
    let(:seller) { create(:user) }
    let!(:product1) { create(:product, user: seller, name: "Product 1") }
    let!(:product2) { create(:product, user: seller, name: "Product 2") }
    let(:variant_category) { create(:variant_category, link: product2) }
    let!(:variant1) { create(:variant, variant_category:, name: "Product 2 - Version 1") }
    let!(:variant2) { create(:variant, variant_category:, name: "Product 2- Version 2") }
    let!(:archived_product) { create(:product, user: seller, archived: true, name: "Archived product") }

    context "when it is not an abandoned cart workflow" do
      it "returns an empty array" do
        workflow = create(:seller_workflow, seller:)
        expect(workflow.abandoned_cart_products).to be_empty
        expect(workflow.abandoned_cart_products(only_product_and_variant_ids: true)).to be_empty
      end
    end

    context "when it is an abandoned cart workflow" do
      context "when 'bought_products', 'bought_variants', 'not_bought_products', and 'not_bought_variants' are not provided" do
        it "returns all products and variants that are not archived" do
          workflow = create(:abandoned_cart_workflow, seller:)
          expect(workflow.abandoned_cart_products).to match_array([{
                                                                    unique_permalink: product1.unique_permalink,
                                                                    external_id: product1.external_id,
                                                                    name: product1.name,
                                                                    thumbnail_url: product1.for_email_thumbnail_url,
                                                                    url: product1.long_url,
                                                                    variants: [],
                                                                    seller: {
                                                                      name: seller.display_name,
                                                                      avatar_url: seller.avatar_url,
                                                                      profile_url: seller.profile_url,
                                                                    }
                                                                  },
                                                                   {
                                                                     unique_permalink: product2.unique_permalink,
                                                                     external_id: product2.external_id,
                                                                     name: product2.name,
                                                                     thumbnail_url: product2.for_email_thumbnail_url,
                                                                     url: product2.long_url,
                                                                     variants: [
                                                                       { external_id: variant1.external_id, name: variant1.name },
                                                                       { external_id: variant2.external_id, name: variant2.name }
                                                                     ],
                                                                     seller: {
                                                                       name: seller.display_name,
                                                                       avatar_url: seller.avatar_url,
                                                                       profile_url: seller.profile_url,
                                                                     }
                                                                   }])
          expect(workflow.abandoned_cart_products(only_product_and_variant_ids: true)).to match_array([[product1.id, []], [product2.id, [variant1.id, variant2.id]]])
        end

        it "includes the product if at least one of its variant is selected" do
          workflow = create(:abandoned_cart_workflow, seller:, bought_variants: [variant1.external_id])
          expect(workflow.abandoned_cart_products).to match_array([{
                                                                    unique_permalink: product2.unique_permalink,
                                                                    external_id: product2.external_id,
                                                                    name: product2.name,
                                                                    thumbnail_url: product2.for_email_thumbnail_url,
                                                                    url: product2.long_url,
                                                                    variants: [{ external_id: variant1.external_id, name: variant1.name }],
                                                                    seller: {
                                                                      name: seller.display_name,
                                                                      avatar_url: seller.avatar_url,
                                                                      profile_url: seller.profile_url,
                                                                    }
                                                                  }])
          expect(workflow.abandoned_cart_products(only_product_and_variant_ids: true)).to match_array([[product2.id, [variant1.id]]])
        end

        it "includes the product along with all its variants if it is selected and one of its variant is selected" do
          workflow = create(:abandoned_cart_workflow, seller:, bought_products: [product2.unique_permalink], bought_variants: [variant2.external_id])
          expect(workflow.abandoned_cart_products).to match_array([{
                                                                    unique_permalink: product2.unique_permalink,
                                                                    external_id: product2.external_id,
                                                                    name: product2.name,
                                                                    thumbnail_url: product2.for_email_thumbnail_url,
                                                                    url: product2.long_url,
                                                                    variants: [
                                                                      { external_id: variant1.external_id, name: variant1.name },
                                                                      { external_id: variant2.external_id, name: variant2.name }
                                                                    ],
                                                                    seller: {
                                                                      name: seller.display_name,
                                                                      avatar_url: seller.avatar_url,
                                                                      profile_url: seller.profile_url,
                                                                    }
                                                                  }])
          expect(workflow.abandoned_cart_products(only_product_and_variant_ids: true)).to match_array([[product2.id, [variant1.id, variant2.id]]])
        end

        it "does not include the product if 'not_bought_products' filter includes it even though one of its variants is selected" do
          workflow = create(:abandoned_cart_workflow, seller:, not_bought_products: [product2.unique_permalink], bought_variants: [variant1.external_id])
          expect(workflow.abandoned_cart_products).to be_empty
          expect(workflow.abandoned_cart_products(only_product_and_variant_ids: true)).to be_empty
        end

        it "does not include a product's variant if 'not_bought_variants' filter includes it" do
          workflow = create(:abandoned_cart_workflow, seller:, bought_products: [product2.unique_permalink], not_bought_variants: [variant2.external_id])
          expect(workflow.abandoned_cart_products).to match_array([{
                                                                    unique_permalink: product2.unique_permalink,
                                                                    external_id: product2.external_id,
                                                                    name: product2.name,
                                                                    thumbnail_url: product2.for_email_thumbnail_url,
                                                                    url: product2.long_url,
                                                                    variants: [{ external_id: variant1.external_id, name: variant1.name }],
                                                                    seller: {
                                                                      name: seller.display_name,
                                                                      avatar_url: seller.avatar_url,
                                                                      profile_url: seller.profile_url,
                                                                    }
                                                                  }])
          expect(workflow.abandoned_cart_products(only_product_and_variant_ids: true)).to match_array([[product2.id, [variant1.id]]])
        end
      end
    end
  end
end
