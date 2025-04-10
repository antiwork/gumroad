# frozen_string_literal: true

describe BundlePresenter do
  include Rails.application.routes.url_helpers

  describe "#bundle_props" do
    let(:seller) { create(:named_seller, :eligible_for_service_products) }
    let(:product) { create(:product, user: seller) }
    let(:versioned_product) { create(:product_with_digital_versions, user: seller, quantity_enabled: true) }
    let(:bundle) do create(:product, :bundle, user: seller, name: "Bundle", description: "I am a bundle!", custom_permalink: "bundle",
                                              customizable_price: true, suggested_price_cents: 200, max_purchase_count: 50, quantity_enabled: true,
                                              should_show_sales_count: true, tag: "hi") end
    let!(:asset_previews) { create_list(:asset_preview, 2, link: bundle) }
    let!(:thumbnail) { create(:thumbnail, product: bundle) }
    let!(:refund_policy) { create(:product_refund_policy, product: bundle, seller:) }

    let!(:other_refund_policy) { create(:product_refund_policy, product: create(:product, user: seller, name: "Other product"), max_refund_period_in_days: 0, fine_print: "This is another refund policy") }

    before do
      create(:call_product, user: seller, name: "Call product does not count towards products_count")
      create(:product, user: seller, archived: true, name: "Archived product")
      bundle.save_custom_button_text_option("pay_prompt")
      bundle.save_custom_summary("To summarize, I am a bundle.")
      bundle.save_custom_attributes({ "Detail 1" => "Value 1" })
      bundle.update(bundle_products:
        [
          build(:bundle_product, product: versioned_product, variant: versioned_product.alive_variants.first, quantity: 2, position: 1),
          build(:bundle_product, product:, position: 0),
        ]
      )
    end

    it "returns the correct props" do
      presenter = described_class.new(bundle:)
      profile_section = create(:seller_profile_products_section, seller:, shown_products: [bundle.id])
      seller.reload
      expect(presenter.bundle_props).to eq(
        {
          bundle: {
            name: "Bundle",
            description: "I am a bundle!",
            custom_permalink: "bundle",
            price_cents: 100,
            customizable_price: true,
            suggested_price_cents: 200,
            **ProductPresenter::InstallmentPlanProps.new(product: presenter.bundle).props,
            custom_button_text_option: "pay_prompt",
            custom_summary: "To summarize, I am a bundle.",
            custom_attributes: { "Detail 1" => "Value 1" },
            max_purchase_count: 50,
            quantity_enabled: true,
            should_show_sales_count: true,
            is_epublication: false,
            product_refund_policy_enabled: false,
            refund_policy: {
              allowed_refund_periods_in_days: [
                {
                  key: 0,
                  value: "No refunds allowed"
                },
                {
                  key: 7,
                  value: "7-day money back guarantee"
                },
                {
                  key: 14,
                  value: "14-day money back guarantee"
                },
                {
                  key: 30,
                  value: "30-day money back guarantee"
                },
                {
                  key: 183,
                  value: "6-month money back guarantee"
                }
              ],
              title: "30-day money back guarantee",
              fine_print: "This is a product-level refund policy",
              fine_print_enabled: true,
              max_refund_period_in_days: 30,
            },
            taxonomy_id: nil,
            tags: ["hi"],
            display_product_reviews: true,
            is_adult: false,
            discover_fee_per_thousand: 100,
            section_ids: [profile_section.external_id],
            is_published: true,
            covers: asset_previews.map(&:as_json),
            products: [
              described_class.bundle_product(
                product:,
                quantity: 1,
                selected_variant_id: nil,
              ),
              described_class.bundle_product(
                product: versioned_product,
                quantity: 2,
                selected_variant_id: versioned_product.alive_variants.first.external_id,
              ),
            ],
            collaborating_user: nil,
            public_files: [],
            audio_previews_enabled: false,
          },
          id: bundle.external_id,
          unique_permalink: bundle.unique_permalink,
          currency_type: "usd",
          products_count: 5,
          thumbnail: thumbnail.as_json,
          ratings: {
            count: 0,
            average: 0,
            percentages: [0, 0, 0, 0, 0],
          },
          sales_count_for_inventory: 0,
          taxonomies: Discover::TaxonomyPresenter.new.taxonomies_for_nav,
          profile_sections: [
            {
              id: profile_section.external_id,
              header: "",
              product_names: ["Bundle"],
              default: true,
            }
          ],
          refund_policies: [
            {
              id: other_refund_policy.external_id,
              title: "No refunds allowed",
              fine_print: "This is another refund policy",
              product_name: "Other product",
              max_refund_period_in_days: 0,
            }
          ],
          seller_refund_policy_enabled: true,
          seller_refund_policy: {
            title: "30-day money back guarantee",
            fine_print: nil,
          },
          is_bundle: true,
          has_outdated_purchases: false,
        }
      )
    end

    context "with public files" do
      let!(:public_file1) { create(:public_file, :with_audio, resource: bundle) }
      let!(:public_file2) { create(:public_file, resource: bundle) }
      let!(:public_file3) { create(:public_file, :with_audio, deleted_at: 1.day.ago) }

      before do
        Feature.activate_user(:audio_previews, bundle.user)

        public_file1.file.analyze
      end

      it "includes public files" do
        props = described_class.new(bundle:).bundle_props[:bundle]

        expect(props[:public_files].sole).to eq(PublicFilePresenter.new(public_file: public_file1).props)
        expect(props[:audio_previews_enabled]).to be(true)
      end
    end
  end

  describe ".bundle_product" do
    let(:product) { create(:product_with_digital_versions, quantity_enabled: true) }

    it "returns the correct props" do
      props = ProductPresenter.card_for_web(product:).merge({
                                                              is_quantity_enabled: true,
                                                              price_cents: 100,
                                                              quantity: 2,
                                                              url: product.long_url,
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

    context "when the product has SKUs enabled" do
      before do
        product.update!(skus_enabled: true, skus: [build(:sku)])
      end

      it "returns the correct props" do
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

    context "product is not a bundle" do
      let(:product) { create(:product) }

      it "sets is_bundle to false" do
        expect(described_class.new(bundle: product).bundle_props[:is_bundle]).to eq(false)
      end
    end
  end
end
