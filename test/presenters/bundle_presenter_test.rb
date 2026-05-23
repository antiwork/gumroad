# frozen_string_literal: true

require "test_helper"

class BundlePresenterTest < ActiveSupport::TestCase
  self.described_class = BundlePresenter


  context_ BundlePresenter do
    include Rails.application.routes.url_helpers

  context_ ".bundle_product" do
      let(:product) { create(:product_with_digital_versions, quantity_enabled: true) }

  test "returns the correct props" do
        props = ProductPresenter.card_for_web(product:).merge({
                                                                is_quantity_enabled: true,
                                                                price_cents: 100,
                                                                quantity: 2,
                                                                url: product.long_url,
                                                                created_at: product.created_at.iso8601,
                                                                variants: {
                                                                  selected_id: product.alive_variants.first.external_id,
                                                                  list: [
                                                                    {
                                                                      description: "",
                                                                      id: product.alive_variants.first.external_id,
                                                                      name: "Untitled 1",
                                                                      price_difference: 0
                                                                    },
                                                                    {
                                                                      description: "",
                                                                      id: product.alive_variants.second.external_id,
                                                                      name: "Untitled 2",
                                                                      price_difference: 0
                                                                    }
                                                                  ],
                                                                }
                                                              })
        expect(described_class.bundle_product(product:, quantity: 2, selected_variant_id: product.alive_variants.first.external_id)).to eq(props)
      end

  context_ "when the product has SKUs enabled" do
        before do
          product.update!(skus_enabled: true, skus: [build(:sku)])
        end

  test "returns the correct props" do
          expect(described_class.bundle_product(product:)[:variants]).to eq(
            {
              list: [
                {
                  description: "",
                  id: product.skus.first.external_id,
                  name: "Large",
                  price_difference: 0,
                }
              ],
              selected_id: product.skus.first.external_id,
            }
          )
        end
      end
    end

  context_ "#shared_props" do
      let(:seller) { create(:named_seller, :eligible_for_service_products) }
      let(:bundle) { create(:product, :bundle, user: seller, name: "Bundle", description: "I am a bundle!", custom_permalink: "bundle") }

  test "returns shared props with minimal bundle data" do
        presenter = described_class.new(bundle:)
        props = presenter.send(:shared_props)

        expect(props.keys).to match_array([:bundle, :id, :unique_permalink, :is_bundle])
        expect(props[:bundle]).to include(:name, :description, :custom_permalink, :is_published)
        expect(props[:id]).to eq(bundle.external_id)
        expect(props[:unique_permalink]).to eq(bundle.unique_permalink)
        expect(props[:is_bundle]).to eq(true)
        expect(props).not_to include(:currency_type, :thumbnail, :taxonomies, :products_count)
      end
    end

  context_ "#edit_product_props" do
      let(:seller) { create(:named_seller, :eligible_for_service_products) }
      let(:bundle) { create(:product, :bundle, user: seller) }

  test "includes shared props plus product-specific props" do
        presenter = described_class.new(bundle:)
        props = presenter.edit_product_props

        expect(props).to include(:bundle, :id, :unique_permalink, :is_bundle)
        expect(props).to include(:currency_type, :thumbnail, :refund_policies, :seller_refund_policy_enabled, :seller_refund_policy)
        expect(props).to include(:sales_count_for_inventory, :ratings)
        expect(props[:currency_type]).to eq(bundle.price_currency_type)
      end
    end

  context_ "#edit_content_props" do
      let(:seller) { create(:named_seller, :eligible_for_service_products) }
      let(:bundle) { create(:product, :bundle, user: seller) }

      before do
        create(:bundle_product, bundle:, product: create(:product, user: seller), quantity: 1, position: 0)
        bundle.reload
      end

  test "includes shared props plus content-specific props" do
        presenter = described_class.new(bundle: bundle.reload)
        props = presenter.edit_content_props

        expect(props).to include(:bundle, :id, :unique_permalink, :is_bundle)
        expect(props).to include(:products_count, :has_outdated_purchases)
        expect(props[:products_count]).to be_a(Integer)
        expect(props[:has_outdated_purchases]).to be_in([true, false])
        expect(props).not_to include(:currency_type, :thumbnail, :taxonomies, :refund_policies)
      end
    end

  context_ "#edit_share_props" do
      let(:seller) { create(:named_seller, :eligible_for_service_products) }
      let(:bundle) { create(:product, :bundle, user: seller) }

  test "includes shared props plus share-specific props" do
        presenter = described_class.new(bundle:)
        props = presenter.edit_share_props

        expect(props).to include(:bundle, :id, :unique_permalink, :is_bundle)
        expect(props).to include(:taxonomies, :profile_sections)
        expect(props).to include(:currency_type, :sales_count_for_inventory, :ratings)
        expect(props).to include(:seller_refund_policy_enabled, :seller_refund_policy)
        expect(props).not_to include(:thumbnail, :refund_policies, :products_count)
      end
    end
  end
end
