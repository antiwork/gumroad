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
      # Its own top-level prop, not a key of `checkout`: it is derived from the cart, so the page
      # re-requests it alone after every cart edit (see the debounced save in Checkout/Show.tsx).
      expect(inertia.props[:checkout_payment]).to eq(
        integration: Checkout::StripePaymentPresenter::STRIPE_CARD_ELEMENT_INTEGRATION,
        fallback_reason: "stripe_payment_element_flag_disabled",
        disable_wallets: false,
        request_apple_pay_merchant_tokens: false,
        payment_element_wallets: false,
        flat_payment_methods: false,
        elements_options: nil,
      )
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
                                               recaptcha_challenge_key: CheckoutRecaptcha.challenge_site_key,
                                               recaptcha_key: GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"),
                                               recaptcha_score_based: false,
                                               saved_credit_card: nil,
                                               state: nil,
                                               tip_options: [0, 15, 20, 25],
                                               us_states: STATES,
                                             })
      expect(inertia.props[:recommended_products]).to be_nil
      expect(inertia.props[:stripe_fonts_css_source]).to eq(SellerProfile.seller_fonts_css_source)
      meta_by_property = inertia.props[:_inertia_meta].filter_map { |t| [t[:property], t[:content]] if t[:property] }.to_h
      expect(meta_by_property).to include(
        "gr:google_analytics:enabled" => "true",
        "gr:fb_pixel:enabled" => "true",
        "gr:tiktok_pixel:enabled" => "true",
        "gr:logged_in_user:id" => "",
        "gr:page:type" => ""
      )
    end

    it "does not raise when checkout params contain nested values" do
      get :show, params: { product: { foo: "bar" }, username: { baz: "qux" }, wishlist: { id: "1" } }

      expect(response).to be_successful
    end

    describe "checkout_style prop" do
      let(:browser_guid) { SecureRandom.uuid }
      let(:branded_seller) do
        create(:user).tap do |seller|
          seller.seller_profile.update!(highlight_color: "#009a49", background_color: "#f8efe3", font: "Roboto Mono")
        end
      end

      before { cookies[:_gumroad_guid] = browser_guid }

      def cart_with(*products)
        create(:cart, :guest, browser_guid:).tap do |cart|
          products.each { create(:cart_product, cart:, product: _1) }
        end
      end

      it "carries the seller's palette when every product in the cart is theirs" do
        cart_with(create(:product, user: branded_seller), create(:product, user: branded_seller))

        get :show

        checkout_style = inertia.props[:checkout_style]
        expect(checkout_style[:css]).to eq(branded_seller.seller_profile.custom_styles)
        expect(checkout_style[:seller_id]).to eq(branded_seller.external_id)
      end

      it "sends the whole palette, not just the accent" do
        cart_with(create(:product, user: branded_seller))

        get :show

        checkout_style = inertia.props[:checkout_style]
        styles = checkout_style[:css]
        # SassC keeps a space inside compressed custom-property values.
        expect(styles).to include("--accent: 0 154 73")
        expect(styles).to include("--body-bg: #f8efe3")
        expect(styles).to include(%(--font-family: "Roboto Mono"))
        expect(styles).to include("body{background-color:#f8efe3")
        expect(checkout_style[:theme]).to eq({
                                               accent_color: "#009a49",
                                               indicator_color: "#009a49",
                                               background_color: "#f8efe3",
                                               text_color: "#000000",
                                               danger_color: "#9b1c12",
                                               font_family: %("Roboto Mono", "ABC Favorit", monospace),
                                             })
      end

      it "floors the indicator colour when the seller's accent is invisible on their background" do
        seller = create(:user).tap { _1.seller_profile.update!(highlight_color: "#ffffff", background_color: "#ffffff") }
        cart_with(create(:product, user: seller))

        get :show

        theme = inertia.props.dig(:checkout_style, :theme)
        expect(theme[:accent_color]).to eq("#ffffff")
        expect(ContrastColor.ratio_between(theme[:indicator_color], "#ffffff"))
          .to be >= ContrastColor::WCAG_AA_NON_TEXT
      end

      it "sends no styles for a cart spanning two sellers" do
        cart_with(create(:product, user: branded_seller), create(:product, user: create(:user)))

        get :show

        expect(inertia.props[:checkout_style]).to be_nil
      end

      it "sends no styles when there is no cart and no product parameter" do
        get :show

        expect(inertia.props[:checkout_style]).to be_nil
      end

      it "sends no styles for an empty cart" do
        cart_with

        get :show

        expect(inertia.props[:checkout_style]).to be_nil
      end

      it "carries the seller's palette for a direct product arrival with no saved cart" do
        product = create(:product, user: branded_seller)

        get :show, params: { product: product.unique_permalink }

        expect(inertia.props.dig(:checkout_style, :css)).to eq(branded_seller.seller_profile.custom_styles)
      end

      it "sends no styles when the arriving product's seller differs from the saved cart's" do
        cart_with(create(:product, user: branded_seller))
        arriving = create(:product, user: create(:user))

        get :show, params: { product: arriving.unique_permalink }

        expect(inertia.props[:checkout_style]).to be_nil
      end

      it "still carries the palette when the arriving product's seller matches the saved cart's" do
        cart_with(create(:product, user: branded_seller))
        arriving = create(:product, user: branded_seller)

        get :show, params: { product: arriving.unique_permalink }

        expect(inertia.props.dig(:checkout_style, :css)).to eq(branded_seller.seller_profile.custom_styles)
      end

      it "ignores an arriving product when the existing cart already fills the product limit" do
        stub_const("Cart::MAX_ALLOWED_CART_PRODUCTS", 1)
        cart_with(create(:product, user: branded_seller))
        arriving = create(:product, user: create(:user))

        get :show, params: { product: arriving.unique_permalink }

        expect(inertia.props.dig(:checkout_style, :css)).to eq(branded_seller.seller_profile.custom_styles)
      end

      it "carries the seller's palette for products added from a wishlist" do
        wishlist = create(:wishlist)
        create(:wishlist_product, wishlist:, product: create(:product, user: branded_seller))
        create(:wishlist_product, wishlist:, product: create(:product, user: branded_seller))

        get :show, params: { wishlist: wishlist.external_id }

        expect(inertia.props.dig(:checkout_style, :css)).to eq(branded_seller.seller_profile.custom_styles)
      end

      it "follows the wishlist, not the product parameter, when both are present" do
        arriving = create(:product, user: create(:user))
        wishlist = create(:wishlist)
        create(:wishlist_product, wishlist:, product: create(:product, user: branded_seller))

        get :show, params: { product: arriving.unique_permalink, wishlist: wishlist.external_id }

        expect(inertia.props.dig(:checkout_style, :css)).to eq(branded_seller.seller_profile.custom_styles)
      end

      it "ignores the product parameter's seller when a wishlist replaces it" do
        arriving = create(:product, user: branded_seller)
        wishlist = create(:wishlist)
        create(:wishlist_product, wishlist:, product: create(:product, user: create(:user)))

        get :show, params: { product: arriving.unique_permalink, wishlist: wishlist.external_id }

        expect(inertia.props.dig(:checkout_style, :css)).not_to eq(branded_seller.seller_profile.custom_styles)
      end

      it "sends no styles when wishlist products differ from the saved cart's seller" do
        cart_with(create(:product, user: branded_seller))
        wishlist = create(:wishlist)
        create(:wishlist_product, wishlist:, product: create(:product, user: create(:user)))

        get :show, params: { wishlist: wishlist.external_id }

        expect(inertia.props[:checkout_style]).to be_nil
      end

      it "sends no styles when an oversized wishlist leaves the checkout empty" do
        stub_const("Cart::MAX_ALLOWED_CART_PRODUCTS", 1)
        wishlist = create(:wishlist)
        create(:wishlist_product, wishlist:, product: create(:product, user: branded_seller))
        create(:wishlist_product, wishlist:, product: create(:product, user: branded_seller))

        get :show, params: { wishlist: wishlist.external_id }

        expect(inertia.props[:checkout_style]).to be_nil
      end

      it "ignores the saved cart when a gift-wishlist arrival clears it" do
        cart_with(create(:product, user: create(:user)))
        wishlist_product = create(
          :wishlist_product,
          wishlist: create(:wishlist),
          product: create(:product, user: branded_seller)
        )

        get :show, params: { gift_wishlist_product: wishlist_product.external_id }

        expect(inertia.props.dig(:checkout_style, :css)).to eq(branded_seller.seller_profile.custom_styles)
      end

      it "sends no styles when the stored colour contains injected SCSS" do
        seller = create(:user)
        # seller_profile is built but unsaved until its first write.
        seller.seller_profile.tap(&:save!).update_column(
          :highlight_color,
          "#ffffff\n)}; } body { display:none !important; } :root { --x: \#{split-color(#ffffff"
        )
        cart_with(create(:product, user: seller))

        get :show

        expect(response).to be_successful
        expect(inertia.props[:checkout_style]).to be_nil
      end

      it "recomputes the palette on the partial request the frontend makes when the cart changes" do
        # The inertia matcher captures only full renders, so inspect the partial response body.
        cart_with(create(:product, user: branded_seller))
        request.headers["X-Inertia"] = "true"
        request.headers["X-Inertia-Partial-Component"] = "Checkout/Show"
        request.headers["X-Inertia-Partial-Data"] = "cart,flash,checkout_style"

        get :show

        expect(response.parsed_body["props"]).to include("checkout_style")
        expect(response.parsed_body.dig("props", "checkout_style", "css")).to include("--accent: 0 154 73")
      end
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

      it "returns empty array when recommendations time out" do
        allow(RecommendedProducts::CheckoutService).to receive(:fetch_for_cart).and_raise(Timeout::Error)

        get :show, params: { cart_product_ids: [cart_product.external_id], on_discover_page: "false", limit: "5" }, session: { recommender_model_name: }

        expect(response).to be_successful
        expect(inertia.component).to eq("Checkout/Show")
        expect(inertia.props.deep_symbolize_keys[:recommended_products]).to eq([])
      end

      it "treats hash-form cart_product_ids as empty instead of raising" do
        expect(RecommendedProducts::CheckoutService).to receive(:fetch_for_cart).with(
          purchaser:,
          cart_product_ids: [],
          recommender_model_name:,
          limit: 5,
          recommendation_type: nil,
        ).and_return([])

        get :show, params: { cart_product_ids: { "0" => "somevalue", "1" => "anothervalue" }, on_discover_page: "false", limit: "5" }, session: { recommender_model_name: }

        expect(response).to be_successful
        expect(inertia.component).to eq("Checkout/Show")
        expect(inertia.props.deep_symbolize_keys[:recommended_products]).to eq([])
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
          email: seller.email,
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

      it "clears a stale accepted offer when the cart item is submitted without one" do
        original_product = create(:product, user: seller)
        offered_product = create(:product, user: seller)
        cross_sell = create(
          :upsell,
          seller:,
          product: offered_product,
          selected_products: [original_product],
          cross_sell: true
        )
        cart = create(:cart, user: controller.logged_in_user)
        cart_product = create(
          :cart_product,
          cart:,
          product: offered_product,
          accepted_offer: cross_sell,
          accepted_offer_details: { original_product_id: original_product.external_id, original_variant_id: nil }
        )

        patch :update, params: {
          cart: {
            items: [{
              product: { id: offered_product.external_id },
              price: offered_product.price_cents,
              quantity: 1,
              rent: false,
              referrer: "direct",
              url_parameters: {},
              accepted_offer: nil
            }],
            discountCodes: []
          }
        }, as: :json

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)
        expect(cart_product.reload).to have_attributes(accepted_offer: nil, accepted_offer_details: {})
      end

      it "forces the cart email to the signed-in user's email regardless of the submitted email" do
        cart = create(:cart, user: seller, email: "stale@example.com")

        patch :update, params: { cart: { email: "stale@example.com", items: [], discountCodes: [] } }, as: :json

        expect(response).to have_http_status(:see_other)
        expect(cart.reload.email).to eq(seller.email)
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

      # Regression: some clients post a cart item that omits `url_parameters` (and `referrer`)
      # entirely. Assigning nil over the empty-hash default made the JSON-schema validation fail,
      # which aborted the whole transaction and left the buyer with a "something went wrong" toast
      # and an empty cart on every save attempt.
      it "saves a new cart product when the item omits url_parameters" do
        product = create(:product)

        expect do
          patch :update, params: {
            cart: {
              items: [
                {
                  product: { id: product.external_id },
                  option_id: nil,
                  recurrence: nil,
                  price: 100,
                  quantity: 1,
                  rent: false,
                  referrer: "direct"
                }
              ],
              discountCodes: []
            }
          }, as: :json
        end.to change(CartProduct, :count).by(1)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to be_nil
        expect(CartProduct.last).to have_attributes(product:, url_parameters: {}, referrer: "direct")
      end

      it "keeps the stored url_parameters and referrer when the item omits them" do
        product = create(:product)
        cart = create(:cart, user: controller.logged_in_user)
        create(:cart_product, cart:, product:, url_parameters: { "utm_source" => "google" }, referrer: "https://example.com")

        patch :update, params: {
          cart: {
            items: [
              {
                product: { id: product.external_id },
                option_id: nil,
                recurrence: nil,
                price: 100,
                quantity: 1,
                rent: false
              }
            ],
            discountCodes: []
          }
        }, as: :json

        expect(response).to have_http_status(:see_other)
        expect(flash[:alert]).to be_nil
        expect(cart.cart_products.alive.sole).to have_attributes(
          url_parameters: { "utm_source" => "google" },
          referrer: "https://example.com"
        )
      end

      it "removes an existing cart product when its quantity is zero" do
        product1 = create(:product, user: seller)
        product2 = create(:product, user: seller)

        cart = create(:cart, user: controller.logged_in_user)
        cart_product1 = create(:cart_product, cart:, product: product1)
        create(:cart_product, cart:, product: product2)

        patch :update, params: {
          cart: {
            items: [
              {
                product: { id: product1.external_id },
                price: product1.price_cents,
                quantity: 0,
                rent: false,
                referrer: "direct",
                url_parameters: {}
              },
              {
                product: { id: product2.external_id },
                price: product2.price_cents,
                quantity: 1,
                rent: false,
                referrer: "direct",
                url_parameters: {}
              }
            ],
            discountCodes: []
          }
        }, as: :json

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)

        cart.reload
        expect(cart_product1.reload).to be_deleted
        expect(cart.alive_cart_products.sole.product).to eq(product2)
      end

      it "soft-deletes a stale cart product with an invalid quantity left over from legacy data" do
        product1 = create(:product, user: seller)
        product2 = create(:product, user: seller)

        cart = create(:cart, user: controller.logged_in_user)
        legacy_cart_product = create(:cart_product, cart:, product: product1)
        # Simulate a legacy/corrupt record that predates the `quantity > 0` validation.
        legacy_cart_product.update_column(:quantity, 0)

        patch :update, params: {
          cart: {
            items: [
              {
                product: { id: product2.external_id },
                price: product2.price_cents,
                quantity: 1,
                rent: false,
                referrer: "direct",
                url_parameters: {}
              }
            ],
            discountCodes: []
          }
        }, as: :json

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to be_nil

        cart.reload
        expect(legacy_cart_product.reload).to be_deleted
        expect(cart.alive_cart_products.sole.product).to eq(product2)
      end

      it "does not create a cart product when its quantity is zero" do
        product = create(:product, user: seller)

        expect do
          patch :update, params: {
            cart: {
              items: [
                {
                  product: { id: product.external_id },
                  price: product.price_cents,
                  quantity: 0,
                  rent: false,
                  referrer: "direct",
                  url_parameters: {}
                }
              ],
              discountCodes: []
            }
          }, as: :json
        end.not_to change(CartProduct, :count)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)
        expect(controller.logged_in_user.alive_cart.alive_cart_products).to be_empty
      end

      it "does not treat a present-but-nonnumeric quantity as a removal" do
        product = create(:product, user: seller)
        cart = create(:cart, user: controller.logged_in_user)
        cart_product = create(:cart_product, cart:, product:)

        patch :update, params: {
          cart: {
            items: [
              {
                product: { id: product.external_id },
                price: product.price_cents,
                quantity: "abc",
                rent: false,
                referrer: "direct",
                url_parameters: {}
              }
            ],
            discountCodes: []
          }
        }, as: :json

        # "abc" is not a numeric zero, so it must NOT silently delete the existing item via the
        # removal path. It falls through and fails the quantity validation, so the transaction
        # rolls back and the existing item is preserved.
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to be_present
        expect(cart_product.reload).not_to be_deleted
      end

      it "does not treat a fractional quantity as a removal" do
        product = create(:product, user: seller)
        cart = create(:cart, user: controller.logged_in_user)
        cart_product = create(:cart_product, cart:, product:)

        patch :update, params: {
          cart: {
            items: [
              {
                product: { id: product.external_id },
                price: product.price_cents,
                quantity: 0.5,
                rent: false,
                referrer: "direct",
                url_parameters: {}
              }
            ],
            discountCodes: []
          }
        }, as: :json

        # 0.5 must NOT be treated as a numeric-zero removal (Integer() would truncate it to 0).
        # It falls through, fails the integer/quantity validation, and the existing item is kept.
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to be_present
        expect(cart_product.reload).not_to be_deleted
      end

      it "returns an error when params are invalid" do
        allow(ErrorNotifier).to receive(:notify)

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
        # Validation failures other than the known quantity/price out-of-range shape are
        # unexpected and must still be reported.
        expect(ErrorNotifier).to have_received(:notify)
      end

      it "returns an error when an item quantity exceeds the integer column limit" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          patch :update, params: {
            cart: {
              items: [
                {
                  product: { id: create(:product).external_id },
                  price: 100,
                  quantity: CartProduct::MAX_QUANTITY + 1,
                  referrer: "direct",
                  url_parameters: {}
                }
              ],
              discountCodes: []
            }
          }, as: :json
        end.not_to change(Cart, :count)

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to eq("Sorry, something went wrong. Please try again.")
        # An out-of-range quantity is expected buyer-supplied bad input already surfaced to the
        # buyer via the alert above — it must not page Sentry on every occurrence.
        expect(ErrorNotifier).not_to have_received(:notify)
      end

      it "returns an error when an item price exceeds the bigint column limit" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          patch :update, params: {
            cart: {
              items: [
                {
                  product: { id: create(:product).external_id },
                  price: CartProduct::MAX_PRICE + 1,
                  quantity: 1,
                  referrer: "direct",
                  url_parameters: {}
                }
              ],
              discountCodes: []
            }
          }, as: :json
        end.not_to change(Cart, :count)

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to eq("Sorry, something went wrong. Please try again.")
        # Same reasoning as the quantity spec above: expected bad input, no Sentry report.
        expect(ErrorNotifier).not_to have_received(:notify)
      end

      it "still reports when an out-of-range quantity is combined with an unrelated validation failure" do
        allow(ErrorNotifier).to receive(:notify)

        expect do
          patch :update, params: {
            cart: {
              items: [
                {
                  product: { id: create(:product).external_id },
                  price: 100,
                  quantity: CartProduct::MAX_QUANTITY + 1,
                  url_parameters: {}
                  # referrer intentionally omitted — its presence validation fails too
                }
              ],
              discountCodes: []
            }
          }, as: :json
        end.not_to change(Cart, :count)

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to eq("Sorry, something went wrong. Please try again.")
        # The record has BOTH the known out-of-range error AND an unexpected one (missing
        # referrer). Suppression only applies when the out-of-range shape is the sole cause,
        # so this mixed failure must still be reported.
        expect(ErrorNotifier).to have_received(:notify)
      end

      it "returns an error when cart contains more than allowed number of cart products" do
        items = (Cart::MAX_ALLOWED_CART_PRODUCTS + 1).times.map { { product: { id: _1 + 1 } }  }
        patch :update, params: { cart: { items: } }, as: :json

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to eq("You cannot add more than 50 products to the cart.")
      end

      it "creates an empty cart when the `items` key is missing from params" do
        expect do
          patch :update, params: { cart: { discountCodes: [] } }, as: :json
        end.to change(Cart, :count).by(1)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)
      end

      it "creates a cart when the `discountCodes` key is missing from params" do
        expect do
          patch :update, params: { cart: { items: [] } }, as: :json
        end.to change(Cart, :count).by(1)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(checkout_path)
        expect(Cart.last.discount_codes).to eq([])
      end

      it "acquires a row lock on the cart to prevent deadlocks" do
        create(:cart, user: seller)

        expect_any_instance_of(Cart).to receive(:lock!).and_call_original

        patch :update, params: { cart: { items: [], discountCodes: [] } }, as: :json

        expect(response).to have_http_status(:see_other)
      end

      it "rescues ActiveRecord::Deadlocked and redirects with an error" do
        allow_any_instance_of(Cart).to receive(:lock!).and_raise(
          ActiveRecord::Deadlocked.new("Deadlock found when trying to get lock")
        )

        patch :update, params: { cart: { items: [], discountCodes: [] } }, as: :json

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to eq("Sorry, something went wrong. Please try again.")
      end

      it "returns an error when the `cart` param is not a Hash" do
        expect do
          patch :update, params: { cart: "foo" }, as: :json
        end.not_to change(Cart, :count)

        expect(response).to have_http_status(:found)
        expect(response).to redirect_to(checkout_path)
        expect(flash[:alert]).to eq("Sorry, something went wrong. Please try again.")
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
