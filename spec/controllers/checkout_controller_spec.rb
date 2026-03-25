# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe CheckoutController, type: :controller, inertia: true do
  let!(:seller) { create(:named_seller) }

  describe "GET show" do
    it "return inertia component with correct props and force enables analytics" do
      browser_guid = SecureRandom.uuid
      cookies[:_gumroad_guid] = browser_guid
      create(:cart, :guest, browser_guid: browser_guid).tap do |cart|
        create(:cart_product, cart: cart, product: create(:product))
      end

      get :show

      expect(response).to be_successful
      expect(inertia.component).to eq("Checkout/Show")
      expect(inertia.props[:cart]).to eq(CartPresenter.new(logged_in_user: nil, ip: request.remote_ip, browser_guid: browser_guid).cart_props)
      expect(inertia.props[:checkout]).to eq({
                                               add_products: [],
                                               address: nil,
                                               ca_provinces: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first),
                                               cart_save_debounce_ms: CheckoutPresenter::CART_SAVE_DEBOUNCE_DURATION_IN_SECONDS.in_milliseconds,
                                               clear_cart: false,
                                               countries: Compliance::Countries.for_select.to_h,
                                               country: nil,
                                               default_tip_option: 0,
                                               discover_url: discover_url(protocol: PROTOCOL, host: DISCOVER_DOMAIN),
                                               gift: nil,
                                               max_allowed_cart_products: Cart::MAX_ALLOWED_CART_PRODUCTS,
                                               paypal_client_id: PAYPAL_PARTNER_CLIENT_ID,
                                               recaptcha_key: GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"),
                                               saved_credit_card: nil,
                                               state: nil,
                                               tip_options: [0, 15, 20, 25],
                                               us_states: STATES,
                                             })
      expect(inertia.props[:recommended_products]).to be_nil
      meta_by_property = inertia.props[:_inertia_meta].filter_map { |t| [t[:property], t[:content]] if t[:property] }.to_h
      expect(meta_by_property).to include(
        "gr:google_analytics:enabled" => "true",
        "gr:fb_pixel:enabled" => "true",
        "gr:logged_in_user:id" => "",
        "gr:page:type" => "",
        "gr:facebook_sdk:enabled" => "true"
      )
    end

    describe "process_cart_id_param check" do
      let(:user) { create(:user) }
      let(:cart) { create(:cart, user:) }
      let(:secure_id) { cart.secure_external_id(scope: "cart_login") }

      context "when user is logged in" do
        before do
          sign_in user
        end

        it "does not redirect when cart_id is blank" do
          get :show

          expect(response).to be_successful
          expect(inertia.props[:_inertia_meta]).to include(
            satisfy { |tag| tag[:property] == "gr:logged_in_user:id" && tag[:content] == user.external_id }
          )
        end

        it "redirects to the same path removing the `cart_id` query param" do
          guest_cart = create(:cart, :guest)
          get :show, params: { cart_id: guest_cart.secure_external_id(scope: "cart_login") }

          expect(response).to redirect_to(checkout_path(referrer: UrlService.discover_domain_with_protocol))
        end
      end

      context "when user is not logged in" do
        it "does not redirect when `cart_id` is blank" do
          get :show

          expect(response).to be_successful
        end

        it "redirects to the same path when `cart_id` is not found" do
          get :show, params: { cart_id: "no-such-cart" }

          expect(response).to redirect_to(checkout_path(referrer: UrlService.discover_domain_with_protocol))
        end

        it "redirects to the same path when an OLD/INSECURE external_id is used" do
          harvested_id = build(:product, id: cart.id).external_id

          get :show, params: { cart_id: harvested_id }

          expect(response).to redirect_to(checkout_path(referrer: UrlService.discover_domain_with_protocol))
          expect(response.location).not_to include("email=")
        end

        it "redirects to the same path when the cart for `cart_id` is deleted" do
          cart.mark_deleted!

          get :show, params: { cart_id: secure_id }

          expect(response).to redirect_to(checkout_path(referrer: UrlService.discover_domain_with_protocol))
        end

        context "when the cart matching the `cart_id` query param belongs to a user" do
          it "redirects to the login page path with `next` param set to the checkout path" do
            get :show, params: { cart_id: secure_id }

            expect(response).to redirect_to(login_url(next: checkout_path(referrer: UrlService.discover_domain_with_protocol), email: cart.user.email))
          end
        end

        context "when the cart matching the `cart_id` query param has the `browser_guid` same as the current `_gumroad_guid` cookie value"  do
          it "redirects to the same path without modifying the cart" do
            browser_guid = SecureRandom.uuid
            cookies[:_gumroad_guid] = browser_guid
            cart = create(:cart, :guest, browser_guid:)
            valid_id = cart.secure_external_id(scope: "cart_login")

            expect do
              expect do
                get :show, params: { cart_id: valid_id }
              end.not_to change { Cart.alive.count }
            end.not_to change { cart.reload }

            expect(response).to redirect_to(checkout_path(referrer: UrlService.discover_domain_with_protocol))
          end
        end

        context "when the cart matching the `cart_id` query param has the `browser_guid` different from the current `_gumroad_guid` cookie value" do
          it "merges the current guest cart with the cart matching the `cart_id` query param" do
            product1 = create(:product)
            product2 = create(:product)

            cart = create(:cart, :guest, browser_guid: SecureRandom.uuid)
            create(:cart_product, cart:, product: product1)

            browser_guid = SecureRandom.uuid
            cookies[:_gumroad_guid] = browser_guid
            current_guest_cart = create(:cart, :guest, browser_guid:, email: "john@example.com")
            create(:cart_product, cart: current_guest_cart, product: product2)

            valid_id = cart.secure_external_id(scope: "cart_login")

            expect do
              get :show, params: { cart_id: valid_id }
            end.to change { Cart.alive.count }.from(2).to(1)

            expect(response).to redirect_to(checkout_path(referrer: UrlService.discover_domain_with_protocol))
            expect(Cart.alive.sole.id).to eq(cart.id)
            expect(current_guest_cart.reload).to be_deleted
            expect(cart.reload.email).to eq("john@example.com")
            expect(cart.alive_cart_products.pluck(:product_id)).to match_array([product1.id, product2.id])
          end
        end
      end
    end

    describe "for partial visits" do
      let(:recommender_model_name) { RecommendedProductsService::MODEL_SALES }
      let(:cart_product) { create(:product) }
      let(:products) { create_list(:product, 5) }
      let(:products_relation) { Link.where(id: products.map(&:id)) }
      let(:product_cards) do
        products[0..2].map do |product|
          ProductPresenter.card_for_web(
            product:,
            request:,
            recommended_by:,
            recommender_model_name:,
            target:,
          )
        end
      end

      before do
        request.headers["X-Inertia"] = "true"
        request.headers["X-Inertia-Partial-Component"] = "Checkout/Show"
        request.headers["X-Inertia-Partial-Data"] = "recommended_products"
        products.last.update!(deleted_at: Time.current)
        products.second_to_last.update!(archived: true)
      end

      let(:recommended_by) { RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION }
      let(:target) { Product::Layout::PROFILE }

      let(:purchaser) { create(:user) }
      let!(:purchase) { create(:purchase, purchaser:) }

      before do
        products.first.update!(user: purchase.link.user)
        cart_product.update!(user: purchase.link.user)
        index_model_records(Link)
        sign_in purchaser
      end

      it "calls CheckoutService and returns product cards" do
        expect(RecommendedProducts::CheckoutService).to receive(:fetch_for_cart).with(
          purchaser:,
          cart_product_ids: [cart_product.id],
          recommender_model_name:,
          limit: 5,
          recommendation_type: nil,
        ).and_call_original
        expect(RecommendedProductsService).to receive(:fetch).with(
          {
            model: RecommendedProductsService::MODEL_SALES,
            ids: [cart_product.id, purchase.link.id],
            exclude_ids: [cart_product.id, purchase.link.id],
            number_of_results: RecommendedProducts::BaseService::NUMBER_OF_RESULTS,
            user_ids: [cart_product.user.id],
          }
        ).and_return(Link.where(id: products.first.id))

        get :show, params: { cart_product_ids: [cart_product.external_id], on_discover_page: "false", limit: "5" }, session: { recommender_model_name: }

        expect(response).to be_successful
        expect(inertia.component).to eq("Checkout/Show")
        expect(inertia.props.deep_symbolize_keys[:recommended_products]).to eq([product_cards.first])
      end
    end
  end

  describe "PATCH update" do
    before do
      request.headers["X-Inertia"] = "true"
      request.headers["X-Inertia-Partial-Component"] = "Checkout/Show"
      request.headers["X-Inertia-Partial-Data"] = "cart, flash"
    end

    context "when user is signed in" do
      before do
        sign_in(seller)
      end

      it "creates an empty cart" do
        expect do
          patch :update, params: { cart: { items: [], discountCodes: [] } }, as: :json
        end.to change(Cart, :count).by(1)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)

        expect(controller.logged_in_user.carts.alive).to be_present
      end

      it "creates and populates a cart" do
        product = create(:product)
        call_start_time = Time.current.round

        expect do
          patch :update, params: {
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

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)

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
          patch :update, params: {
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

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)

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
          patch :update, params: { cart: { email: "john@example.com", items: [], discountCodes: [] } }, as: :json
        end.not_to change { Cart.count }
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)
        expect(cart.reload.browser_guid).to eq("456")
      end

      it "does not change products that are already deleted" do
        product = create(:product)

        cart = create(:cart, user: controller.logged_in_user, return_url: "https://example.com")
        deleted_cart_product = create(:cart_product, cart: cart, product: product, deleted_at: 1.minute.ago)

        expect do
          patch :update, params: {
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

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)

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
          patch :update, params: {
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

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to eq("Sorry, something went wrong. Please try again.")
      end

      it "returns an error when cart contains more than allowed number of cart products" do
        items = (Cart::MAX_ALLOWED_CART_PRODUCTS + 1).times.map { { product: { id: _1 + 1 } }  }
        patch :update, params: { cart: { items: } }, as: :json

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to eq("You cannot add more than 50 products to the cart.")
      end
    end

    context "when user is not signed in" do
      it "creates a new cart" do
        expect do
          patch :update, params: { cart: { email: "john@example.com", items: [], discountCodes: [] } }, as: :json
        end.to change(Cart, :count).by(1)
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)
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
          patch :update, params: { cart: { email: "john@example.com", items: [], discountCodes: [] } }, as: :json
        end.not_to change(Cart, :count)
        cart.reload
        expect(cart.email).to eq("john@example.com")
        expect(cart.ip_address).to eq("127.1.2.4")
        expect(cart.browser_guid).to eq("123")
      end
    end
  end
end
