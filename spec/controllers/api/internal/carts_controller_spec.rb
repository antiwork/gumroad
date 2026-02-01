# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::CartsController do
  let!(:seller) { create(:named_seller) }

  describe "PUT update" do
    context "when user is signed in" do
      before do
        sign_in(seller)
      end

      it "creates an empty cart" do
        expect do
          put :update, params: { cart: { items: [], discountCodes: [] } }, as: :json
        end.to change(Cart, :count).by(1)

        expect(response).to be_successful

        expect(controller.logged_in_user.carts.alive).to be_present
      end

      it "creates and populates a cart" do
        product = create(:product)
        call_start_time = Time.current.round

        expect do
          put :update, params: {
            cart: {
              email: "john@example.com",
              returnUrl: "https://example.com",
              rejectPppDiscount: false,
              discountCodes: [{ code: "BLACKFRIDAY", fromUrl: false }],
              items: [{
                product: { id: product.external_id },
                price: product.price_cents,
                quantity: 1,
                rent: false,
                referrer: "direct",
                call_start_time: call_start_time.iso8601,
                url_parameters: {}
              }]
            }
          }, as: :json
        end.to change(Cart, :count).by(1)

        cart = controller.logged_in_user.alive_cart
        expect(cart).to have_attributes(
          email: "john@example.com",
          return_url: "https://example.com",
          reject_ppp_discount: false,
          discount_codes: [{ "code" => "BLACKFRIDAY", "fromUrl" => false }]
        )
        expect(cart.ip_address).to be_present
        expect(cart.browser_guid).to be_present
        expect(cart.cart_products.sole).to have_attributes(
          product:,
          price: product.price_cents,
          quantity: 1,
          rent: false,
          referrer: "direct",
          call_start_time:,
          url_parameters: {},
          pay_in_installments: false
        )
      end

      it "updates an existing cart" do
        product1 = create(:membership_product_with_preset_tiered_pwyw_pricing, user: seller)
        product2 = create(:product, user: seller)
        product3 = create(:product, user: seller, price_cents: 1000)
        product3_offer = create(:upsell, product: product3, seller:)
        create(:product_installment_plan, link: product3)
        affiliate = create(:direct_affiliate)

        cart = create(:cart, user: controller.logged_in_user, return_url: "https://example.com")
        create(
          :cart_product,
          cart: cart,
          product: product1,
          option: product1.variants.first,
          recurrence: BasePrice::Recurrence::MONTHLY,
          call_start_time: 1.week.from_now.round
        )
        create(:cart_product, cart: cart, product: product2)

        new_call_start_time = 2.weeks.from_now.round
        expect do
          put :update, params: {
            cart: {
              returnUrl: nil,
              items: [
                {
                  product: { id: product1.external_id },
                  option_id: product1.variants.first.external_id,
                  recurrence: BasePrice::Recurrence::YEARLY,
                  price: 999,
                  quantity: 2,
                  rent: false,
                  referrer: "direct",
                  call_start_time: new_call_start_time.iso8601,
                  url_parameters: {},
                  pay_in_installments: false
                },
                {
                  product: { id: product3.external_id },
                  price: product3.price_cents,
                  quantity: 1,
                  rent: false,
                  referrer: "google.com",
                  url_parameters: { utm_source: "google" },
                  affiliate_id: affiliate.external_id_numeric,
                  recommended_by: RecommendationType::GUMROAD_PRODUCTS_FOR_YOU_RECOMMENDATION,
                  recommender_model_name: RecommendedProductsService::MODEL_SALES,
                  accepted_offer: { id: product3_offer.external_id, original_product_id: product3.external_id },
                  pay_in_installments: true
                }
              ],
              discountCodes: []
            }
          }, as: :json
        end.not_to change(Cart, :count)

        cart.reload
        expect(cart.return_url).to be_nil
        expect(cart.cart_products.size).to eq 3
        expect(cart.cart_products.first).to have_attributes(
          product: product1,
          option: product1.variants.first,
          recurrence: BasePrice::Recurrence::YEARLY,
          price: 999,
          quantity: 2,
          rent: false,
          referrer: "direct",
          call_start_time: new_call_start_time,
          url_parameters: {},
          pay_in_installments: false
        )
        expect(cart.cart_products.second).to be_deleted
        expect(cart.cart_products.third).to have_attributes(
          product: product3,
          price: product3.price_cents,
          quantity: 1,
          rent: false,
          referrer: "google.com",
          url_parameters: { "utm_source" => "google" },
          affiliate:,
          recommended_by: RecommendationType::GUMROAD_PRODUCTS_FOR_YOU_RECOMMENDATION,
          recommender_model_name: RecommendedProductsService::MODEL_SALES,
          accepted_offer: product3_offer,
          accepted_offer_details: { "original_product_id" => product3.external_id, "original_variant_id" => nil },
          pay_in_installments: true
        )
      end

      it "updates `browser_guid` with the value of the `_gumroad_guid` cookie" do
        cart = create(:cart, user: seller, browser_guid: "123")
        cookies[:_gumroad_guid] = "456"
        expect do
          put :update, params: { cart: { email: "john@example.com", items: [], discountCodes: [] } }, as: :json
        end.not_to change { Cart.count }
        expect(cart.reload.browser_guid).to eq("456")
      end

      it "does not change products that are already deleted" do
        product = create(:product)

        cart = create(:cart, user: controller.logged_in_user, return_url: "https://example.com")
        deleted_cart_product = create(:cart_product, cart: cart, product: product, deleted_at: 1.minute.ago)

        expect do
          put :update, params: {
            cart: {
              returnUrl: nil,
              items: [
                {
                  product: { id: product.external_id },
                  option_id: nil,
                  recurrence: nil,
                  price: 999,
                  quantity: 1,
                  rent: false,
                  referrer: "direct",
                  url_parameters: {}
                }
              ],
              discountCodes: []
            }
          }, as: :json
        end.not_to change { deleted_cart_product.reload.updated_at }

        cart.reload
        expect(cart.cart_products.deleted.sole).to eq(deleted_cart_product)
        expect(cart.cart_products.alive.sole).to have_attributes(
          product:,
          option: nil,
          recurrence: nil,
          price: 999,
          quantity: 1,
          rent: false,
          referrer: "direct",
          url_parameters: {},
          deleted_at: nil
        )
      end

      it "returns an error when params are invalid" do
        expect do
          put :update, params: {
            cart: {
              items: [
                {
                  product: { id: create(:product).external_id },
                  price: nil
                }
              ],
              discountCodes: []
            }
          }, as: :json
        end.not_to change(Cart, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("error" => "Sorry, something went wrong. Please try again.")
      end

      it "returns an error when cart contains more than allowed number of cart products" do
        items = (Cart::MAX_ALLOWED_CART_PRODUCTS + 1).times.map { { product: { id: _1 + 1 } }  }
        put :update, params: { cart: { items: }, as: :json }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("error" => "You cannot add more than 50 products to the cart.")
      end
    end

    context "when user is not signed in" do
      it "creates a new cart" do
        expect do
          put :update, params: { cart: { email: "john@example.com", items: [], discountCodes: [] } }, as: :json
        end.to change(Cart, :count).by(1)
        expect(response).to be_successful
        cart = Cart.last
        expect(cart.user).to be_nil
        expect(cart.email).to eq("john@example.com")
        expect(cart.ip_address).to be_present
        expect(cart.browser_guid).to be_present
      end

      it "updates an existing cart" do
        cart = create(:cart, :guest, browser_guid: "123")
        cookies[:_gumroad_guid] = cart.browser_guid
        request.remote_ip = "127.1.2.4"
        expect do
          put :update, params: { cart: { email: "john@example.com", items: [], discountCodes: [] } }, as: :json
        end.not_to change(Cart, :count)
        cart.reload
        expect(cart.email).to eq("john@example.com")
        expect(cart.ip_address).to eq("127.1.2.4")
        expect(cart.browser_guid).to eq("123")
      end
    end
  end
end
