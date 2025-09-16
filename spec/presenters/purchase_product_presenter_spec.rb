# frozen_string_literal: true

require "spec_helper"

describe PurchaseProductPresenter, :versioning do
  include Rails.application.routes.url_helpers

  describe "#product_props" do
    let(:product_created_at) { 5.minutes.ago }
    let(:seller) { create(:named_seller) }

    context "when the product is a membership" do
      before do
        travel_to product_created_at do
          @product = create(:membership_product, unique_permalink: "test", name: "Product title v1", user: seller)
          @product.save_custom_attributes(
            [
              { "name" => "Attribute 1", "value" => "Value 1" },
              { "name" => "Attribute 2", "value" => "Value 2" }
            ]
          )
          @asset_preview = create(:asset_preview, link: @product)
        end

        travel_to (product_created_at + 1.minute) do
          @purchase = create(:membership_purchase, :with_review, link: product)
        end
      end

      let(:product) { @product }
      let(:asset_preview) { @asset_preview }
      let(:purchase) { @purchase }
      let(:presenter) { described_class.new(purchase) }

      it "returns properties for the product page" do
        expect(presenter.product_props).to eq(
          product: {
            price_cents: 0,
            covers: [product.asset_previews.first.as_json],
            currency_code: "usd",
            custom_view_content_button_text: nil,
            custom_button_text_option: nil,
            description_html: "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes.",
            pwyw: nil,
            is_sales_limited: false,
            is_tiered_membership: true,
            is_legacy_subscription: false,
            long_url: short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol),
            main_cover_id: asset_preview.guid,
            name: "Product title v1",
            permalink: "test",
            preorder: nil,
            duration_in_months: nil,
            quantity_remaining: nil,
            ratings: {
              count: 1,
              average: 5,
              percentages: [0, 0, 0, 0, 100],
            },
            seller: {
              avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
              id: seller.external_id,
              name: "Seller",
              profile_url: "http://seller.test.gumroad.com:31337",
            },
            is_compliance_blocked: false,
            is_published: true,
            is_physical: false,
            attributes: [
              { name: "Attribute 1", value: "Value 1" },
              { name: "Attribute 2", value: "Value 2" }
            ],
            free_trial: nil,
            is_quantity_enabled: false,
            is_multiseat_license: false,
            is_stream_only: false,
            options: [{
              id: product.variant_categories[0].variants[0].external_id,
              description: "",
              name: "Product title v1",
              is_pwyw: false,
              price_difference_cents: nil,
              quantity_left: nil,
              recurrence_price_values: {
                "monthly" => {
                  price_cents: 100,
                  suggested_price_cents: nil
                }
              },
              duration_in_minutes: nil,
            }],
            rental: nil,
            recurrences: {
              default: "monthly",
              enabled: [{ id: product.prices.alive.first.external_id, recurrence: "monthly", price_cents: 0 }]
            },
            rental_price_cents: nil,
            sales_count: nil,
            summary: nil,
            thumbnail_url: nil,
            analytics: product.analytics_data,
            has_third_party_analytics: false,
            ppp_details: nil,
            can_edit: false,
            refund_policy: nil
          },
          discount_code: nil,
          purchase: nil
        )
      end

      context "when the product was updated after the purchase" do
        before do
          asset_preview.mark_deleted!
          create(:asset_preview, link: product)

          product.update!(
            name: "Product title v2"
          )
          product.save_custom_attributes(
            [
              { "name" => "Attribute 3", "value" => "Value 3" }
            ]
          )
        end

        it "returns the product props at the time of purchase" do
          expect(presenter.product_props[:product][:name]).to eq("Product title v1")
          expect(presenter.product_props[:product][:covers]).to eq([asset_preview.as_json])
          expect(presenter.product_props[:product][:main_cover_id]).to eq(asset_preview.guid)
          expect(presenter.product_props[:product][:attributes]).to eq(
            [
              { name: "Attribute 1", value: "Value 1" },
              { name: "Attribute 2", value: "Value 2" }
            ]
          )
        end
      end

      context "when the purchase has a refund policy" do
        let!(:refund_policy) do
          purchase.create_purchase_refund_policy!(
            title: RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30],
            fine_print: "This is the fine print.",
            max_refund_period_in_days: 30
          )
        end

        it "returns the refund policy" do
          expect(presenter.product_props[:product][:refund_policy]).to eq(
            {
              title: refund_policy.title,
              fine_print: "<p>This is the fine print.</p>",
              updated_at: refund_policy.updated_at
            }
          )
        end

        context "when the fine_print is empty" do
          before do
            refund_policy.update!(fine_print: "")
          end

          it "returns the refund policy" do
            expect(presenter.product_props[:product][:refund_policy]).to eq(
              {
                title: refund_policy.title,
                fine_print: nil,
                updated_at: refund_policy.updated_at
              }
            )
          end
        end
      end
    end

    context "when the product is not a membership" do
      before do
        travel_to product_created_at do
          @product = create(:product_with_digital_versions, unique_permalink: "test", name: "Product title v1", user: seller)
        end
      end

      let(:product) { @product }
      let(:purchase) { create(:membership_purchase, :with_review, link: product) }
      let(:presenter) { described_class.new(purchase) }

      it "returns properties for the product page" do
        expect(presenter.product_props).to eq(
          product: {
            price_cents: 100,
            covers: [],
            currency_code: "usd",
            custom_view_content_button_text: nil,
            custom_button_text_option: nil,
            description_html: "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes.",
            pwyw: nil,
            is_sales_limited: false,
            is_tiered_membership: false,
            is_legacy_subscription: false,
            long_url: short_link_url(product.unique_permalink, host: seller.subdomain_with_protocol),
            main_cover_id: nil,
            name: "Product title v1",
            permalink: "test",
            preorder: nil,
            duration_in_months: nil,
            quantity_remaining: nil,
            ratings: {
              count: 1,
              average: 5,
              percentages: [0, 0, 0, 0, 100],
            },
            seller: {
              avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
              id: seller.external_id,
              name: "Seller",
              profile_url: "http://seller.test.gumroad.com:31337",
            },
            is_compliance_blocked: false,
            is_published: true,
            is_physical: false,
            attributes: [],
            free_trial: nil,
            is_quantity_enabled: false,
            is_multiseat_license: false,
            is_stream_only: false,
            options: [
              product.variant_categories[0].variants[0].to_option,
              product.variant_categories[0].variants[1].to_option,
            ],
            rental: nil,
            recurrences: nil,
            rental_price_cents: nil,
            sales_count: nil,
            summary: nil,
            thumbnail_url: nil,
            analytics: product.analytics_data,
            has_third_party_analytics: false,
            ppp_details: nil,
            can_edit: false,
            refund_policy: nil,
          },
          discount_code: nil,
          purchase: nil
        )
      end
    end
  end
end
