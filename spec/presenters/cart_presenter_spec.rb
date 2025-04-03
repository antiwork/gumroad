# frozen_string_literal: true

require "spec_helper"

describe CartPresenter do
  describe "#cart_props" do
    let(:user) { create(:user) }
    let(:ip) { "127.0.0.1" }
    let(:browser_guid) { SecureRandom.uuid }
    let(:presenter) do
      described_class.new(logged_in_user: user, ip:, browser_guid:)
    end

    context "when the user is not logged in" do
      let(:user) { nil }

      it "returns props for the alive guest cart matching the `browser_guid`" do
        create(:cart, :guest, browser_guid:, email: "john@example.com")
        create(:cart, user: create(:user), browser_guid:, email: "jane@example.com")

        expect(presenter.cart_props).to match(
          email: "john@example.com",
          returnUrl: "",
          rejectPppDiscount: false,
          discountCodes: [],
          items: [],
        )
      end

      it "returns nil if no matching guest cart is found" do
        expect(presenter.cart_props).to be_nil
      end
    end

    context "when the user has no cart" do
      it "returns nil" do
        expect(presenter.cart_props).to be_nil
      end
    end

    context "when the user has a cart with items" do
      let(:cart) { create(:cart, user:, email: "john@example.com") }
      let(:simple_product) { create(:product) }
      let(:recurring_product) { create(:membership_product_with_preset_tiered_pricing) }
      let(:call_product) { create(:call_product, price_cents: 1000, installment_plan: create(:product_installment_plan)) }
      let(:call_start_time) { 1.hour.from_now.round }

      before do
        create(:cart_product, cart:, product: simple_product, referrer: "google.com", call_start_time:, url_parameters: { "utm_source" => "google" })
        create(:cart_product, cart:, product: recurring_product, option: recurring_product.variants.first, recurrence: BasePrice::Recurrence::MONTHLY)
        create(:cart_product, cart:, product: call_product, option: call_product.variants.first, call_start_time:, pay_in_installments: true)
      end

      it "returns the correct props" do
        expect(presenter.cart_props).to match(
          {
            email: "john@example.com",
            returnUrl: "",
            rejectPppDiscount: false,
            discountCodes: [],
            items: [
              {
                product: a_hash_including(permalink: call_product.unique_permalink),
                price: 1000,
                option_id: call_product.variants.first.external_id,
                rent: false,
                recurrence: nil,
                quantity: 1,
                affiliate_id: nil,
                recommended_by: nil,
                recommender_model_name: nil,
                accepted_offer: nil,
                url_parameters: {},
                referrer: "direct",
                call_start_time: call_start_time,
                pay_in_installments: true,
              },
              {
                product: a_hash_including(permalink: recurring_product.unique_permalink),
                price: 300,
                option_id: recurring_product.variants.first.external_id,
                rent: false,
                recurrence: BasePrice::Recurrence::MONTHLY,
                quantity: 1,
                affiliate_id: nil,
                recommended_by: nil,
                recommender_model_name: nil,
                accepted_offer: nil,
                url_parameters: {},
                referrer: "direct",
                call_start_time: nil,
                pay_in_installments: false,
              },
              {
                product: a_hash_including(permalink: simple_product.unique_permalink),
                price: 100,
                option_id: nil,
                rent: false,
                recurrence: nil,
                quantity: 1,
                affiliate_id: nil,
                recommended_by: nil,
                recommender_model_name: nil,
                accepted_offer: nil,
                url_parameters: { "utm_source" => "google" },
                referrer: "google.com",
                call_start_time: nil,
                pay_in_installments: false,
              },
            ],
          }
        )
      end
    end

    context "with discount codes and offers" do
      context "when the user has accepeted an upsell" do
        let(:discount_codes) do
          [
            { "code" => "SAVEMONEY", "fromUrl" => false },
            { "code" => "INVALIDCODE", "fromUrl" => true }
          ]
        end
        let(:cart) { create(:cart, user:, discount_codes:) }
        let(:product) { create(:product) }
        let(:offer_code) { create(:offer_code, code: "SAVEMONEY", amount_cents: 100, user: product.user, products: [product]) }
        let(:upsell) { create(:upsell, seller: product.user, offer_code:, product:) }

        before do
          create(:cart_product, cart:, product:, accepted_offer: upsell, accepted_offer_details: { original_product_id: upsell.product.external_id, original_variant_id: nil })
        end

        it "returns the correct props" do
          expect(presenter.cart_props).to match(
            {
              email: nil,
              returnUrl: "",
              rejectPppDiscount: false,
              discountCodes: [
                {
                  code: "SAVEMONEY",
                  fromUrl: false,
                  products: {
                    product.unique_permalink => {
                      type: "fixed",
                      cents: 100,
                      product_ids: [product.external_id],
                      expires_at: nil,
                      minimum_quantity: nil,
                      duration_in_billing_cycles: nil,
                      minimum_amount_cents: nil,
                    }
                  },
                },
                {
                  code: "INVALIDCODE",
                  fromUrl: true,
                  products: [],
                }
              ],
              items: [
                {
                  product: a_hash_including(permalink: product.unique_permalink),
                  price: 100,
                  option_id: nil,
                  rent: false,
                  recurrence: nil,
                  quantity: 1,
                  affiliate_id: nil,
                  recommended_by: nil,
                  recommender_model_name: nil,
                  url_parameters: {},
                  referrer: "direct",
                  call_start_time: nil,
                  pay_in_installments: false,
                  accepted_offer: {
                    id: upsell.external_id,
                    original_product_id: upsell.product.external_id,
                    original_variant_id: nil,
                    discount: {
                      type: "fixed",
                      cents: 100,
                      product_ids: [product.external_id],
                      expires_at: nil,
                      minimum_quantity: nil,
                      duration_in_billing_cycles: nil,
                      minimum_amount_cents: nil,
                    },
                  },
                },
              ],
            }
          )
        end
      end

      context "when the user has accepted a cross-sell" do
        let(:user) { nil }
        let(:cart) { create(:cart, :guest, browser_guid:) }
        let(:seller) { create(:user) }
        let(:product) { create(:product, user: seller) }
        let(:offered_product) { create(:product, user: seller) }
        let(:cross_sell) { create(:upsell, seller:, product: offered_product, selected_products: [product], offer_code: create(:offer_code, user: seller, products: [offered_product]), cross_sell: true) }

        before do
          create(:cart_product, cart:, product:)
          create(:cart_product, cart:, product: offered_product, accepted_offer: cross_sell, accepted_offer_details: { original_product_id: product.external_id, original_variant_id: nil })
        end

        it "returns the correct props" do
          expect(presenter.cart_props).to match(a_hash_including(
            discountCodes: [],
            items: [
              a_hash_including(
                product: a_hash_including(permalink: offered_product.unique_permalink),
                accepted_offer: a_hash_including(
                  id: cross_sell.external_id,
                  original_product_id: product.external_id,
                  original_variant_id: nil,
                  discount: a_hash_including(
                    type: "fixed",
                    cents: 100,
                    product_ids: [offered_product.external_id],
                  ),
                ),
              ),
              a_hash_including(
                product: a_hash_including(permalink: product.unique_permalink),
              ),
            ]
          ))
        end
      end
    end
  end
end
