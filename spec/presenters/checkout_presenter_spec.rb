# frozen_string_literal: true

describe CheckoutPresenter do
  include ManageSubscriptionHelpers
  include Rails.application.routes.url_helpers

  describe "#checkout_props" do
    before do
      vcr_turned_on do
        VCR.use_cassette "checkout presenter saved credit card" do
          @user = create(:user, currency_type: "jpy", credit_card: create(:credit_card))
        end
      end
      @instance = described_class.new(logged_in_user: @user, ip: "104.193.168.19")

      TipOptionsService.set_tip_options([5, 15, 25])
      TipOptionsService.set_default_tip_option(15)
    end

    let(:browser_guid) { SecureRandom.uuid }

    it "returns basic props for the checkout page" do
      expect(@instance.checkout_props(params: {}, browser_guid:)).to eq(
        discover_url: discover_url(protocol: PROTOCOL, host: DISCOVER_DOMAIN),
        countries: Compliance::Countries.for_select.to_h,
        us_states: STATES,
        ca_provinces: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first),
        country: "US",
        state: "CA",
        address: { city: nil, street: nil, zip: nil },
        add_products: [],
        clear_cart: false,
        gift: nil,
        saved_credit_card: { expiration_date: "12/23", number: "**** **** **** 4242", type: "visa", requires_mandate: false },
        recaptcha_key: GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"),
        paypal_client_id: PAYPAL_PARTNER_CLIENT_ID,
        cart: nil,
        max_allowed_cart_products: Cart::MAX_ALLOWED_CART_PRODUCTS,
        tip_options: [5, 15, 25],
        default_tip_option: 15,
      )
    end

    it "returns cart props" do
      create(:cart, user: @user)
      expect(@instance.checkout_props(params: {}, browser_guid:)).to include(cart: { email: nil, returnUrl: "", rejectPppDiscount: false, discountCodes: [], items: [] })
    end

    it "allows adding a product" do
      product = create(:product_with_digital_versions, name: "Sample Product", description: "Simple description", user: create(:named_user), duration_in_months: 6)
      product.alive_variants.first.update!(max_purchase_count: 0)
      upsell = create(:upsell, seller: product.user, product:, description: "Visit https://google.com to learn more about this offer")
      create(:upsell_variant, upsell:, selected_variant: product.alive_variants.first, offered_variant: product.alive_variants.second)
      create(:upsell_variant, upsell:, selected_variant: product.alive_variants.second, offered_variant: product.alive_variants.first)
      offered_product = create(:product_with_digital_versions, user: product.user)
      offered_product.alive_variants.first.update!(max_purchase_count: 0)
      create(:upsell, name: "Cross-sell 1", selected_products: [product], seller: product.user, product: offered_product, variant: offered_product.alive_variants.first, cross_sell: true, replace_selected_products: true)
      cross_sell2 = create(:upsell, name: "Cross-sell 2", description: "https://gumroad.com is the best!", selected_products: [product], seller: product.user, product: offered_product, offer_code: create(:offer_code, user: product.user, products: [offered_product]), cross_sell: true)
      options = product.options
      params = { product: product.unique_permalink, recommended_by: "discover", option: options[1][:id] }
      expect(@instance.checkout_props(params:, browser_guid:)).to eq(
        discover_url: discover_url(protocol: PROTOCOL, host: DISCOVER_DOMAIN),
        countries: Compliance::Countries.for_select.to_h,
        us_states: STATES,
        ca_provinces: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first),
        country: "US",
        state: "CA",
        address: { city: nil, street: nil, zip: nil },
        saved_credit_card: { expiration_date: "12/23", number: "**** **** **** 4242", type: "visa", requires_mandate: false },
        recaptcha_key: GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"),
        paypal_client_id: PAYPAL_PARTNER_CLIENT_ID,
        gift: nil,
        clear_cart: false,
        add_products: [{
          product: {
            permalink: product.unique_permalink,
            id: product.external_id,
            name: "Sample Product",
            creator: {
              name: product.user.name,
              profile_url: product.user.profile_url(recommended_by: "discover"),
              avatar_url: product.user.avatar_url,
              id: product.user.external_id,
            },
            url: product.long_url,
            thumbnail_url: nil,
            native_type: "digital",
            quantity_remaining: nil,
            is_preorder: false,
            is_multiseat_license: false,
            free_trial: nil,
            options: [options.first.merge({ upsell_offered_variant_id: options.second[:id] }), options.second.merge({ upsell_offered_variant_id: nil })],
            require_shipping: false,
            shippable_country_codes: [],
            custom_fields: [],
            supports_paypal: nil,
            has_offer_codes: false,
            has_tipping_enabled: false,
            analytics: product.analytics_data,
            exchange_rate: 1,
            currency_code: "usd",
            is_legacy_subscription: false,
            is_quantity_enabled: false,
            is_tiered_membership: false,
            price_cents: 100,
            pwyw: nil,
            installment_plan: nil,
            recurrences: nil,
            duration_in_months: 6,
            rental: nil,
            ppp_details: nil,
            can_gift: true,
            upsell: {
              id: upsell.external_id,
              description: 'Visit <a href="https://google.com" target="_blank" rel="noopener">https://google.com</a> to learn more about this offer',
              text: "Take advantage of this excellent offer!",
            },
            archived: false,
            cross_sells: [
              {
                id: cross_sell2.external_id,
                replace_selected_products: false,
                text: "Take advantage of this excellent offer!",
                description: '<a href="https://gumroad.com" target="_blank" rel="noopener">https://gumroad.com</a> is the best!',
                ratings: { count: 0, average: 0 },
                discount: {
                  type: "fixed",
                  cents: 100,
                  product_ids: [offered_product.external_id],
                  expires_at: nil,
                  minimum_quantity: nil,
                  duration_in_billing_cycles: nil,
                  minimum_amount_cents: nil,
                },
                offered_product: @instance.checkout_product(offered_product, offered_product.cart_item({}), {}, include_cross_sells: false),
              },
            ],
            bundle_products: [],
          },
          price: product.price_cents,
          option_id: options[1][:id],
          rent: false,
          quantity: nil,
          recurrence: nil,
          recommended_by: "discover",
          affiliate_id: nil,
          recommender_model_name: nil,
          call_start_time: nil,
          accepted_offer: nil,
          pay_in_installments: false
        }],
        max_allowed_cart_products: Cart::MAX_ALLOWED_CART_PRODUCTS,
        tip_options: [5, 15, 25],
        default_tip_option: 15,
        cart: nil,
      )
    end

    it "allows adding products from a wishlist" do
      wishlist = create(:wishlist)
      physical_product = create(:product, :is_physical)
      create(:wishlist_product, wishlist:, product: physical_product, quantity: 5)
      rental_product = create(:product, purchase_type: :buy_and_rent, rental_price_cents: 99)
      create(:wishlist_product, wishlist:, product: rental_product, rent: true)
      subscription_product = create(:subscription_product)
      create(:wishlist_product, wishlist:, product: subscription_product, recurrence: "monthly")
      versioned_product = create(:product_with_digital_versions)
      create(:wishlist_product, wishlist:, product: versioned_product, variant: versioned_product.alive_variants.first)

      params = {
        wishlist: wishlist.external_id,
        recommended_by: "discover"
      }

      expect(@instance.checkout_props(params:, browser_guid:)).to include(
        add_products: [
          {
            product: a_hash_including(id: physical_product.external_id),
            price: physical_product.price_cents,
            option_id: nil,
            rent: false,
            quantity: 5,
            recurrence: nil,
            recommended_by: "discover",
            affiliate_id: wishlist.user.global_affiliate.external_id_numeric.to_s,
            recommender_model_name: nil,
            call_start_time: nil,
            accepted_offer: nil,
            pay_in_installments: false
          },
          {
            product: a_hash_including(id: rental_product.external_id),
            price: rental_product.rental_price_cents,
            option_id: nil,
            rent: true,
            quantity: 1,
            recurrence: nil,
            recommended_by: "discover",
            affiliate_id: wishlist.user.global_affiliate.external_id_numeric.to_s,
            recommender_model_name: nil,
            call_start_time: nil,
            accepted_offer: nil,
            pay_in_installments: false
          },
          {
            product: a_hash_including(id: subscription_product.external_id),
            price: subscription_product.price_cents,
            option_id: nil,
            rent: false,
            quantity: 1,
            recurrence: "monthly",
            recommended_by: "discover",
            affiliate_id: wishlist.user.global_affiliate.external_id_numeric.to_s,
            recommender_model_name: nil,
            call_start_time: nil,
            accepted_offer: nil,
            pay_in_installments: false
          },
          {
            product: a_hash_including(id: versioned_product.external_id),
            price: versioned_product.price_cents,
            option_id: versioned_product.options.first[:id],
            rent: false,
            quantity: 1,
            recurrence: nil,
            recommended_by: "discover",
            affiliate_id: wishlist.user.global_affiliate.external_id_numeric.to_s,
            recommender_model_name: nil,
            call_start_time: nil,
            accepted_offer: nil,
            pay_in_installments: false
          }
        ]
      )
    end

    it "does not add deleted wishlist products" do
      wishlist = create(:wishlist)
      alive_product = create(:wishlist_product, wishlist:)
      create(:wishlist_product, wishlist:, deleted_at: Time.current)

      params = {
        wishlist: wishlist.external_id,
        recommended_by: "discover"
      }

      expect(@instance.checkout_props(params:, browser_guid:)[:add_products].sole[:product][:id]).to eq alive_product.product.external_id
    end

    context "when gifting a wishlist product" do
      let(:user) { create(:user, name: "Jane Gumroad") }
      let(:wishlist) { create(:wishlist, user:) }
      let(:wishlist_product) { create(:wishlist_product, wishlist:) }

      let(:params) { { gift_wishlist_product: wishlist_product.external_id } }

      it "clears the cart and gifts the product" do
        expect(@instance.checkout_props(params:, browser_guid:)).to include(
          clear_cart: true,
          gift: {
            type: "anonymous",
            id: wishlist.user.external_id,
            name: wishlist.user.name,
            note: ""
          },
          add_products: [{
            product: a_hash_including(id: wishlist_product.product.external_id),
            price: wishlist_product.product.price_cents,
            option_id: nil,
            rent: false,
            quantity: 1,
            recurrence: nil,
            recommended_by: RecommendationType::WISHLIST_RECOMMENDATION,
            affiliate_id: nil,
            recommender_model_name: nil,
            call_start_time: nil,
            accepted_offer: nil,
            pay_in_installments: false
          }]
        )
      end

      it "falls back to the username when the user has not set a name" do
        wishlist.user.update!(name: nil)

        expect(@instance.checkout_props(params:, browser_guid:)).to include(
          gift: {
            type: "anonymous",
            id: wishlist.user.external_id,
            name: wishlist.user.username,
            note: ""
          }
        )
      end
    end

    it "does not add unavailable wishlist products" do
      wishlist = create(:wishlist)
      available_product = create(:product)
      create(:wishlist_product, wishlist:, product: available_product)
      unpublished_product = create(:product, purchase_disabled_at: Time.current)
      create(:wishlist_product, wishlist:, product: unpublished_product)
      suspended_user_product = create(:product, user: create(:tos_user))
      create(:wishlist_product, wishlist:, product: suspended_user_product)

      params = {
        wishlist: wishlist.external_id,
        recommended_by: "discover"
      }

      expect(@instance.checkout_props(params:, browser_guid:)).to include(
        add_products: [
          {
            product: a_hash_including(id: available_product.external_id),
            price: available_product.price_cents,
            option_id: nil,
            rent: false,
            quantity: 1,
            recurrence: nil,
            recommended_by: "discover",
            affiliate_id: wishlist.user.global_affiliate.external_id_numeric.to_s,
            recommender_model_name: nil,
            call_start_time: nil,
            accepted_offer: nil,
            pay_in_installments: false
          }
        ]
      )
    end

    it "respects single-unit currencies in exchange_rate" do
      $currency_namespace = Redis::Namespace.new(:currencies, redis: $redis)
      $currency_namespace.set("JPY", 149)
      product = create(:product, price_cents: 1000, price_currency_type: "jpy")
      params = { product: product.unique_permalink }
      expect(@instance.checkout_props(params:, browser_guid:)[:add_products].first[:product][:exchange_rate]).to eq 1.49
    end

    context "when all PayPal sales are disabled" do
      let!(:product) { create(:product) }

      it "returns nil for supports_paypal when the creator does not have their PayPal account connected" do
        Feature.deactivate(:disable_braintree_sales)

        expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to eq "braintree"

        Feature.activate(:disable_paypal_sales)

        expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to be_nil
      end

      it "returns nil for supports_paypal when the creator has their PayPal account connected" do
        create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L", user: product.user, country: "GB", currency: "gbp")
        create(:user_compliance_info, user: product.user)

        expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to eq "native"

        Feature.activate(:disable_paypal_sales)

        expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to be_nil
      end
    end

    context "when PayPal Connect sales are disabled" do
      before do
        Feature.activate(:disable_paypal_connect_sales)
        Feature.deactivate(:disable_braintree_sales)
      end

      context "when the product is a recurring subscription" do
        let (:product) { create(:subscription_product) }

        it "returns nil for supports_paypal" do
          expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to be_nil
        end
      end

      context "when the product is not a recurring subscription" do
        let (:product) { create(:product) }

        it "returns braintree for supports_paypal" do
          expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to eq "braintree"
        end

        it "returns nil for supports_paypal if Braintree sales are also disabled" do
          Feature.activate(:disable_braintree_sales)
          expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to be_nil
        end
      end
    end

    context "when PayPal Connect sales are disabled for NSFW products" do
      before do
        Feature.activate(:disable_nsfw_paypal_connect_sales)
      end

      context "when the product is NSFW" do
        let(:product) { create(:product, is_adult: true) }

        it "returns nil for supports_paypal" do
          expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to be_nil
        end
      end
    end

    context "when Braintree sales are disabled" do
      before do
        Feature.activate(:disable_braintree_sales)
      end

      it "returns nil for supports_paypal if product doesn't support native PayPal" do
        product = create(:product)
        expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to be_nil
      end

      it "returns native for supports_paypal if product supports native PayPal" do
        seller = create(:user)
        create(:merchant_account_paypal, user: seller)
        product = create(:product, user: seller)
        expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to eq "native"
      end

      it "returns nil for supports_paypal if native PayPal is also disabled" do
        Feature.activate(:disable_paypal_connect_sales)

        seller = create(:user)
        create(:merchant_account_paypal, user: seller)
        product = create(:product, user: seller)

        expect(@instance.checkout_props(params: { product: product.unique_permalink }, browser_guid:)[:add_products].first[:product][:supports_paypal]).to be_nil
      end
    end

    context "when the product is a bundle product" do
      let(:bundle) { create(:product, is_bundle: true) }

      before do
        create(:bundle_product, bundle:, product: create(:product, :with_custom_fields, user: bundle.user, require_shipping: true), quantity: 2, position: 1)
        versioned_product = create(:product_with_digital_versions, user: bundle.user)
        versioned_product.alive_variants.second.update(price_difference_cents: 200)
        create(:bundle_product, bundle:, product: versioned_product, variant: versioned_product.alive_variants.second, position: 0)
        bundle.reload
      end

      it "includes the bundle products" do
        product_props = @instance.checkout_props(params: { product: bundle.unique_permalink }, browser_guid:)[:add_products].first[:product]
        expect(product_props[:require_shipping]).to eq(true)
        expect(product_props[:bundle_products]).to eq(
          [
            {
              product_id: bundle.bundle_products.second.product.external_id,
              name: "The Works of Edgar Gumstein",
              native_type: "digital",
              quantity: 1,
              thumbnail_url: nil,
              variant: { id: bundle.bundle_products.second.variant.external_id, name: "Untitled 2" },
              custom_fields: [],
            },
            {
              product_id: bundle.bundle_products.first.product.external_id,
              name: "The Works of Edgar Gumstein",
              native_type: "digital",
              quantity: 2,
              thumbnail_url: nil,
              variant: nil,
              custom_fields: [
                {
                  id: bundle.bundle_products.first.product.custom_fields.first.external_id,
                  name: "Text field",
                  required: false,
                  collect_per_product: false,
                  type: "text",
                },
                {
                  id: bundle.bundle_products.first.product.custom_fields.second.external_id,
                  name: "Checkbox field",
                  required: true,
                  collect_per_product: false,
                  type: "checkbox",
                },
                {
                  id: bundle.bundle_products.first.product.custom_fields.third.external_id,
                  name: "http://example.com",
                  required: true,
                  collect_per_product: false,
                  type: "terms",
                },
              ],
            },
          ]
        )
      end
    end
  end

  describe "#subscription_manager_props", :vcr do
    context "tiered membership product" do
      before :each do
        @product = create(:membership_product_with_preset_tiered_pricing)
        @default_tier = @product.default_tier
        @product_price = @product.prices.alive.find_by(recurrence: "monthly")
        @tier_price = @default_tier.prices.alive.find_by(recurrence: "monthly")
        @original_price_cents = @tier_price.price_cents
        @subscription = create(:subscription, link: @product, price: @product.default_price, credit_card: create(:credit_card), cancelled_at: 1.week.from_now)
        @purchase = create(:membership_purchase, link: @product, subscription: @subscription,
                                                 email: "jgumroad@example.com", full_name: "Jane Gumroad",
                                                 street_address: "100 Main St", city: "San Francisco", state: "CA",
                                                 zip_code: "00000", country: "USA", variant_attributes: [@default_tier],
                                                 price_cents: @original_price_cents)
      end

      it "returns subscription data object for the subscription manage page" do
        @purchase.update!(offer_code: create(:offer_code, products: [@product]))
        @subscription.reload
        tier1 = @product.tier_category.variants.first
        tier2 = @product.tier_category.variants.second

        result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription: @subscription)
        expect(result).to eq({
                               product: {
                                 name: @product.name,
                                 native_type: @product.native_type,
                                 supports_paypal: nil,
                                 creator: {
                                   id: @product.user.external_id,
                                   name: @product.user.username,
                                   profile_url: @product.user.profile_url,
                                   avatar_url: @product.user.avatar_url,
                                 },
                                 require_shipping: false,
                                 shippable_country_codes: [],
                                 custom_fields: [],
                                 currency_code: "usd",
                                 permalink: @product.unique_permalink,
                                 options: [{
                                   description: "",
                                   id: tier1.external_id,
                                   is_pwyw: false,
                                   name: "First Tier",
                                   price_difference_cents: nil,
                                   quantity_left: nil,
                                   recurrence_price_values: { "monthly" => { price_cents: 300, suggested_price_cents: nil } },
                                   duration_in_minutes: nil,
                                 }, {
                                   description: "",
                                   id: tier2.external_id,
                                   is_pwyw: false,
                                   name: "Second Tier",
                                   price_difference_cents: 0,
                                   quantity_left: nil,
                                   recurrence_price_values: { "monthly" => { price_cents: 500, suggested_price_cents: nil } },
                                   duration_in_minutes: nil,
                                 }],
                                 pwyw: nil,
                                 price_cents: 0,
                                 installment_plan: nil,
                                 is_tiered_membership: true,
                                 is_legacy_subscription: false,
                                 recurrences: [{ id: @product_price.external_id, price_cents: 0, recurrence: "monthly" }],
                                 exchange_rate: 1,
                                 is_multiseat_license: false,
                               },
                               subscription: {
                                 id: @subscription.external_id,
                                 option_id: @default_tier.external_id,
                                 recurrence: "monthly",
                                 quantity: 1,
                                 price: @original_price_cents,
                                 prorated_discount_price_cents: @subscription.prorated_discount_price_cents,
                                 alive: false,
                                 pending_cancellation: true,
                                 discount: {
                                   type: "fixed",
                                   cents: 100,
                                   product_ids: [@product.external_id],
                                   expires_at: nil,
                                   minimum_quantity: nil,
                                   duration_in_billing_cycles: nil,
                                   minimum_amount_cents: nil,
                                 },
                                 end_time_of_subscription: @subscription.end_time_of_subscription.iso8601,
                                 successful_purchases_count: 1,
                                 is_in_free_trial: false,
                                 is_test: false,
                                 is_overdue_for_charge: false,
                                 is_gift: false,
                                 is_installment_plan: false,
                               },
                               contact_info: { city: "San Francisco", country: "US", email: @subscription.email, full_name: "Jane Gumroad", state: "CA", street: "100 Main St", zip: "00000" },
                               discover_url: discover_url(protocol: PROTOCOL, host: DISCOVER_DOMAIN),
                               countries: Compliance::Countries.for_select.to_h,
                               us_states: STATES,
                               ca_provinces: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first),
                               used_card: { expiration_date: "12/24", number: "**** **** **** 4242", type: "visa", requires_mandate: false },
                               recaptcha_key: GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"),
                               paypal_client_id: PAYPAL_PARTNER_CLIENT_ID,
                             })
      end

      context "membership missing variants" do
        before :each do
          @purchase.variant_attributes = []
        end

        it "returns the default tier variant ID" do
          result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription: @subscription)

          expect(result[:subscription][:option_id]).to eq @default_tier.external_id
        end

        context "when price has changed" do
          it "uses the new price for the default tier price" do
            @tier_price.update!(price_cents: @original_price_cents + 500)

            result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription: @subscription)

            variant_data = result[:product][:options][0]

            expect(variant_data[:id]).to eq @default_tier.external_id
            expect(variant_data[:recurrence_price_values]["monthly"][:price_cents]).to eq @tier_price.price_cents
          end
        end
      end

      context "membership for PWYW tier" do
        before do
          @default_tier.update!(customizable_price: true)
          @pwyw_price_cents = @original_price_cents + 200
          @subscription.original_purchase.update!(displayed_price_cents: @pwyw_price_cents)
        end

        it "returns the correct current subscription price and tier displayed price" do
          result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription: @subscription)
          current_subscription_price = result[:subscription][:price]
          displayed_tier_price = result[:product][:options][0][:recurrence_price_values]["monthly"][:price_cents]

          expect(current_subscription_price).to eq @pwyw_price_cents
          expect(displayed_tier_price).to eq @original_price_cents
        end

        it "returns the tier price when the tier price is lower than the current plan price" do
          new_price = @pwyw_price_cents - 100
          @tier_price.update!(price_cents: new_price)
          result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription: @subscription)
          displayed_tier_price = result[:product][:options][0][:recurrence_price_values]["monthly"][:price_cents]

          expect(displayed_tier_price).to eq new_price
        end

        it "returns the tier price when tier price is greater than the current plan price" do
          new_price = @pwyw_price_cents + 100
          @tier_price.update!(price_cents: new_price)
          result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription: @subscription)
          displayed_tier_price = result[:product][:options][0][:recurrence_price_values]["monthly"][:price_cents]

          expect(displayed_tier_price).to eq new_price
        end
      end

      context "when the original purchase's country is nil" do
        before do
          @subscription.original_purchase.update!(country: nil, ip_country: "Brazil")
        end

        it "uses the IP country" do
          result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription: @subscription)
          expect(result[:contact_info][:country]).to eq "BR"
        end
      end
    end

    context "non-tiered membership product" do
      context "subscription missing variants" do
        it "returns a nil option_id" do
          subscription = create(:subscription, link: create(:subscription_product))
          create(:purchase, subscription:, is_original_subscription_purchase: true)

          result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription:)

          expect(result[:subscription][:option_id]).to eq nil
        end
      end
    end

    context "gifted membership product" do
      let(:subscription) { create(:subscription, link: create(:subscription_product), user: nil) }
      let(:gift) { create(:gift, giftee_email: "giftee@example.com") }
      let!(:original_purchase) { create(:membership_purchase, link: subscription.link, gift_given: gift, is_gift_sender_purchase: true, email: "gifter@example.com", subscription:) }

      it "returns gift information" do
        result = described_class.new(logged_in_user: nil, ip: "127.0.0.1").subscription_manager_props(subscription:)

        expect(result[:subscription][:is_gift]).to eq true
        expect(result[:subscription][:end_time_of_subscription]).to eq subscription.end_time_of_subscription.iso8601
        expect(result[:subscription][:successful_purchases_count]).to eq 1
      end
    end
  end

  describe ".saved_card" do
    it "returns nil when no card is given" do
      expect(CheckoutPresenter.saved_card(nil)).to eq nil
    end

    it "returns nil when a paypal card is given" do
      expect(CheckoutPresenter.saved_card(CreditCard.new(card_type: "paypal", visual: "buyer@example.com"))).to eq nil
    end

    it "returns a serialized card when a credit card is given" do
      card = CreditCard.new(card_type: "visa", visual: "**** **** **** 4242", expiry_month: "9", expiry_year: "2028")
      expect(CheckoutPresenter.saved_card(card)).to eq ({ type: "visa", number: "**** **** **** 4242", expiration_date: "09/28", requires_mandate: false })
    end
  end
end
