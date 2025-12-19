# frozen_string_literal: true

require "spec_helper"

describe Api::V2::LicensesController do
  include ActionView::Helpers::DateHelper

  before do
    travel_to(Time.current)
    @product = create(:product, is_licensed: true, custom_permalink: "max")
    @license = create(:license, link: @product)
    @purchase = create(:purchase, link: @product, license: @license)
  end

  shared_examples_for "a licenseable" do |action, product_identifier_key, product_identifier_value|
    before do
      @product_identifier = { product_identifier_key => @product.send(product_identifier_value) }
    end

    context "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @product.user.id,
                                                   scopes: "edit_products")
      end

      it "returns the correct JSON when it modifies the license state" do
        put action, params: { access_token: @token.token, license_key: @purchase.license.serial }.merge(@product_identifier)

        @purchase.reload

        expect(response.parsed_body).to eq({
          success: true,
          uses: 0,
          purchase: {
            id: ObfuscateIds.encrypt(@purchase.id),
            product_name: @product.name,
            created_at: @purchase.created_at,
            variants: "",
            custom_fields: [],
            quantity: 1,
            refunded: false,
            chargebacked: false,
            email: @purchase.email,
            seller_id: ObfuscateIds.encrypt(@purchase.seller.id),
            product_id: ObfuscateIds.encrypt(@product.id),
            permalink: @product.general_permalink,
            product_permalink: @product.long_url,
            short_product_id: @product.unique_permalink,
            price: @purchase.price_cents,
            currency: @product.price_currency_type,
            order_number: @purchase.external_id_numeric,
            sale_id: ObfuscateIds.encrypt(@purchase.id),
            sale_timestamp: @purchase.created_at,
            license_key: @purchase.license.serial,
            is_gift_receiver_purchase: false,
            disputed: false,
            dispute_won: false,
            gumroad_fee: @purchase.fee_cents,
            discover_fee_charged: @purchase.was_discover_fee_charged,
            can_contact: @purchase.can_contact,
            referrer: @purchase.referrer,
            card: {
              bin: nil,
              expiry_month: @purchase.card_expiry_month,
              expiry_year: @purchase.card_expiry_year,
              type: @purchase.card_type,
              visual: @purchase.card_visual,
            }
          }
        }.as_json)
      end

      it "returns an error response when a user provides a license key that does not exist for the provided product" do
        put action, params: { access_token: @token.token, license_key: "Does not exist" }.merge(@product_identifier)

        expect(response.code.to_i).to eq(404)
        expect(response.parsed_body).to eq({
          success: false,
          message: "That license does not exist for the provided product."
        }.as_json)
      end

      it "returns an error response when a user provides a non existent product" do
        put action, params: { access_token: @token.token, license_key: "Does not exist" }.merge(@product_identifier)

        expect(response.code.to_i).to eq(404)
        expect(response.parsed_body).to eq({
          success: false,
          message: "That license does not exist for the provided product."
        }.as_json)
      end

      it "does not allow modifying someone else's license" do
        other_product = create(:product, is_licensed: true)
        other_purchase = create(:purchase, link: other_product, license: create(:license, link: other_product))

        put action, params: { access_token: @token.token, product_permalink: other_product.custom_permalink, license_key: other_purchase.license.serial }

        expect(response.parsed_body).to eq({
          success: false,
          message: "That license does not exist for the provided product."
        }.as_json)
      end
    end

    context "when logged in with view_sales scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @product.user.id,
                                                   scopes: "view_sales")
      end

      it "responds with 403 forbidden" do
        put action, params: { access_token: @token.token, license_key: @purchase.license.serial }.merge(@product_identifier)

        expect(response.code).to eq "403"
      end
    end
  end

  describe "PUT 'enable'" do
    before do
      @app = create(:oauth_application, owner: create(:user))
    end

    it_behaves_like "a licenseable", :enable, :product_permalink, :unique_permalink
    it_behaves_like "a licenseable", :enable, :product_permalink, :custom_permalink
    it_behaves_like "a licenseable", :enable, :product_id, :external_id

    context "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @product.user.id,
                                                   scopes: "edit_products")
      end

      shared_examples_for "enable license" do |product_identifier_key, product_identifier_value|
        before do
          @product_identifier = { product_identifier_key => @product.send(product_identifier_value) }
        end

        it "it enables the license" do
          @purchase.license.disable!
          put :enable, params: { access_token: @token.token, license_key: @purchase.license.serial }.merge(@product_identifier)

          @purchase.reload
          expect(@purchase.license.disabled?).to eq false
        end

        it "returns a 404 error if the license user is not the current resource owner" do
          token = create("doorkeeper/access_token", application: @app,
                                                    resource_owner_id: create(:user).id,
                                                    scopes: "edit_products")
          put :enable, params: { access_token: token.token, license_key: @purchase.license.serial }.merge(@product_identifier)
          expect(response.code.to_i).to eq(404)
        end
      end

      it_behaves_like "enable license", :product_permalink, :unique_permalink
      it_behaves_like "enable license", :product_permalink, :custom_permalink
      it_behaves_like "enable license", :product_id, :external_id
    end
  end

  describe "PUT 'disable'" do
    before do
      @app = create(:oauth_application, owner: create(:user))
    end

    it_behaves_like "a licenseable", :disable, :product_permalink, :unique_permalink
    it_behaves_like "a licenseable", :disable, :product_permalink, :custom_permalink
    it_behaves_like "a licenseable", :disable, :product_id, :external_id

    context "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @product.user.id,
                                                   scopes: "edit_products")
      end

      shared_examples_for "disable license" do |product_identifier_key, product_identifier_value|
        before do
          @product_identifier = { product_identifier_key => @product.send(product_identifier_value) }
        end

        it "it disables the license" do
          put :disable, params: { access_token: @token.token, license_key: @purchase.license.serial }.merge(@product_identifier)

          @purchase.reload
          expect(@purchase.license.disabled?).to eq true
        end

        it "returns a 404 error if the license user is not the current resource owner" do
          token = create("doorkeeper/access_token", application: @app,
                                                    resource_owner_id: create(:user).id,
                                                    scopes: "edit_products")
          put :disable, params: { access_token: token.token, license_key: @purchase.license.serial }.merge(@product_identifier)
          expect(response.code.to_i).to eq(404)
        end
      end

      it_behaves_like "disable license", :product_permalink, :unique_permalink
      it_behaves_like "disable license", :product_permalink, :custom_permalink
      it_behaves_like "disable license", :product_id, :external_id
    end
  end

  describe "PUT 'rotate'" do
    before do
      @app = create(:oauth_application, owner: create(:user))
    end

    it_behaves_like "a licenseable", :rotate, :product_permalink, :unique_permalink
    it_behaves_like "a licenseable", :rotate, :product_permalink, :custom_permalink
    it_behaves_like "a licenseable", :rotate, :product_id, :external_id

    context "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app,
                                                   resource_owner_id: @product.user.id,
                                                   scopes: "edit_products")
      end

      shared_examples_for "rotate license" do |product_identifier_key, product_identifier_value|
        before do
          @product_identifier = { product_identifier_key => @product.send(product_identifier_value) }
        end

        it "rotates the license key" do
          old_serial = @purchase.license.serial
          put :rotate, params: { access_token: @token.token, license_key: @purchase.license.serial }.merge(@product_identifier)

          @purchase.reload
          expect(@purchase.license.serial).not_to eq old_serial
          expect(response.parsed_body["purchase"]["license_key"]).to eq @purchase.license.serial
        end

        it "returns a 404 error if the license user is not the current resource owner" do
          token = create("doorkeeper/access_token", application: @app,
                                                    resource_owner_id: create(:user).id,
                                                    scopes: "edit_products")
          put :rotate, params: { access_token: token.token, license_key: @purchase.license.serial }.merge(@product_identifier)
          expect(response.code.to_i).to eq(404)
        end
      end

      it_behaves_like "rotate license", :product_permalink, :unique_permalink
      it_behaves_like "rotate license", :product_permalink, :custom_permalink
      it_behaves_like "rotate license", :product_id, :external_id
    end
  end

  describe "POST 'verify'" do
    shared_examples_for "verify license" do |product_identifier_key, product_identifier_value|
      before do
        @product_identifier = { product_identifier_key => @product.send(product_identifier_value) }
      end

      it "returns an error response when a user provides a license key that does not exist for the provided product" do
        post :verify, params: { license_key: "Does not exist" }.merge(@product_identifier)
        expect(response.code.to_i).to eq(404)
        expect(response.parsed_body).to eq({
          success: false,
          message: "That license does not exist for the provided product."
        }.as_json)
      end

      it "returns the correct json when a valid product and license key are provided" do
        post :verify, params: { license_key: @purchase.license.serial }.merge(@product_identifier)
        expect(response.code.to_i).to eq(200)
        @purchase.reload
        expect(response.parsed_body).to eq({
          success: true,
          uses: 1,
          purchase: {
            id: ObfuscateIds.encrypt(@purchase.id),
            product_name: @product.name,
            created_at: @purchase.created_at,
            variants: "",
            custom_fields: [],
            quantity: 1,
            refunded: false,
            chargebacked: false,
            email: @purchase.email,
            seller_id: ObfuscateIds.encrypt(@purchase.seller.id),
            product_id: ObfuscateIds.encrypt(@product.id),
            permalink: @product.general_permalink,
            product_permalink: @product.long_url,
            short_product_id: @product.unique_permalink,
            price: @purchase.price_cents,
            currency: @product.price_currency_type,
            order_number: @purchase.external_id_numeric,
            sale_id: ObfuscateIds.encrypt(@purchase.id),
            sale_timestamp: @purchase.created_at,
            license_key: @purchase.license.serial,
            is_gift_receiver_purchase: false,
            disputed: false,
            dispute_won: false,
            gumroad_fee: @purchase.fee_cents,
            discover_fee_charged: @purchase.was_discover_fee_charged,
            can_contact: @purchase.can_contact,
            referrer: @purchase.referrer,
            card: {
              bin: nil,
              expiry_month: @purchase.card_expiry_month,
              expiry_year: @purchase.card_expiry_year,
              type: @purchase.card_type,
              visual: @purchase.card_visual,
            }
          }
        }.as_json)
        post :verify, params: { product_permalink: @product.custom_permalink, license_key: @purchase.license.serial }
        expect(response.code.to_i).to eq(200)
        expect(response.parsed_body["uses"]).to eq 2
      end

      it "returns correct json for purchase with quantity" do
        @purchase = create(:purchase, link: @product, license: create(:license, link: @product), quantity: 2)
        post :verify, params: { license_key: @purchase.license.serial }.merge(@product_identifier)
        expect(response.code.to_i).to eq(200)
        @purchase.reload
        expect(response.parsed_body["purchase"]["quantity"]).to eq 2
      end

      it "returns correct json for refunded and chargebacked purchases" do
        refunded_purchase = create(:purchase, link: @product, stripe_refunded: true, license: create(:license, link: @product))
        post :verify, params: { license_key: refunded_purchase.license.serial }.merge(@product_identifier)
        expect(response.code.to_i).to eq(200)
        refunded_purchase.reload
        expect(response.parsed_body["purchase"]["refunded"]).to eq true
        chargebacked_purchase = create(:purchase, link: @product, chargeback_date: Time.current, license: create(:license, link: @product))
        post :verify, params: { license_key: chargebacked_purchase.license.serial }.merge(@product_identifier)
        expect(response.code.to_i).to eq(200)
        chargebacked_purchase.reload
        expect(response.parsed_body["purchase"]["chargebacked"]).to eq true
      end

      it "doesn't increment uses count when 'increase_uses_count' parameter is set to false" do
        post :verify, params: { license_key: @purchase.license.serial }.merge(@product_identifier)
        expect(response.code.to_i).to eq(200)
        expect(response.parsed_body["uses"]).to eq(1)

        # string "false"
        post :verify, params: { license_key: @purchase.license.serial, increment_uses_count: "false" }.merge(@product_identifier)
        expect(response.code.to_i).to eq(200)
        expect(response.parsed_body["uses"]).to eq(1)

        # boolean false
        post :verify, params: { license_key: @purchase.license.serial, increment_uses_count: false }.merge(@product_identifier), as: :json
        expect(response.code.to_i).to eq(200)
        expect(response.parsed_body["uses"]).to eq(1)
      end

      it "increments the uses column as needed" do
        post :verify, params: { license_key: @purchase.license.serial }.merge(@product_identifier)
        post :verify, params: { license_key: @purchase.license.serial }.merge(@product_identifier)
        post :verify, params: { license_key: @purchase.license.serial }.merge(@product_identifier)

        expect(@purchase.license.reload.uses).to eq(3)
      end

      it "accepts license keys from imported customers" do
        imported_customer = create(:imported_customer, link: @product, importing_user: @product.user)
        post :verify, params: { license_key: imported_customer.license_key }.merge(@product_identifier)
        expect(response.code.to_i).to eq(200)
        expect(response.parsed_body["uses"]).to eq(1)
        expect(response.parsed_body["imported_customer"]).to eq JSON.parse(imported_customer.to_json(without_license_key: true))
        expect(response.parsed_body["imported_customer"]["license_key"]).to eq nil
      end

      it "indicates that a license has been disabled" do
        purchase = create(:purchase, link: @product,
                                     license: create(:license, link: @product, disabled_at: Date.current))

        post :verify, params: { license_key: purchase.license.serial }.merge(@product_identifier)

        expect(response.code.to_i).to eq(404)
        expect(response.parsed_body).to eq({
          success: false,
          message: "This license key has been disabled."
        }.as_json)
      end

      it "doesn't verify authenticity token" do
        expect(controller).not_to receive(:verify_authenticity_token)

        purchase = create(:purchase, link: @product, license: create(:license, link: @product))
        post :verify, params: { license_key: purchase.license.serial }.merge(@product_identifier)
      end

      context "when access to purchase is revoked" do
        before do
          @purchase.update!(is_access_revoked: true)
        end

        it "responds with an error message" do
          post :verify, params: { license_key: @purchase.license.serial }.merge(@product_identifier)

          expect(response).to have_http_status(:not_found)
          expect(response.parsed_body).to eq({
            success: false,
            message: "Access to the purchase associated with this license has expired."
          }.as_json)
        end
      end
    end

    it_behaves_like "verify license", :product_permalink, :unique_permalink
    it_behaves_like "verify license", :product_permalink, :custom_permalink
    it_behaves_like "verify license", :product_id, :external_id

    it "indicates if a subscription is ended for the license key", :vcr do
      product = create(:membership_product, subscription_duration: :monthly)
      subscription = create(:subscription, link: product)
      original_purchase = create(:purchase, is_original_subscription_purchase: true, link: product,
                                            subscription:, license: create(:license, link: product))
      subscription.end_subscription!

      post :verify, params: { product_permalink: product.unique_permalink, license_key: original_purchase.license.serial }

      expect(response).to be_successful
      expect(response.parsed_body["purchase"]["subscription_ended_at"]).to eq Time.current.as_json
    end

    it "indicates if a subscription is cancelled for the license key", :vcr do
      product = create(:membership_product, user: create(:user), subscription_duration: :monthly)
      subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: product)
      original_purchase = create(:purchase, is_original_subscription_purchase: true, link: product,
                                            subscription:, license: create(:license, link: product))
      recurring_charges = []
      3.times { recurring_charges << create(:purchase, subscription:, is_original_subscription_purchase: false) }
      recurring_charges.each do |recurring_charge|
        expect(recurring_charge.license).to eq(original_purchase.license)
      end
      subscription.cancel!
      post :verify, params: { product_permalink: product.unique_permalink, license_key: original_purchase.license.serial }
      expect(response.code.to_i).to eq(200)
      original_purchase.reload
      expect(response.parsed_body["purchase"]["subscription_cancelled_at"]).to eq subscription.end_time_of_subscription.as_json
    end

    it "accepts license keys from subscription products and returns relevant information", :vcr do
      product = create(:subscription_product, user: create(:user))
      subscription = create(:subscription, user: create(:user, credit_card: create(:credit_card)), link: product)
      original_purchase = create(:purchase, is_original_subscription_purchase: true, link: product,
                                            subscription:, license: create(:license, link: product))
      recurring_charges = []
      3.times { recurring_charges << create(:purchase, subscription:, is_original_subscription_purchase: false) }
      recurring_charges.each do |recurring_charge|
        expect(recurring_charge.license).to eq(original_purchase.license)
      end
      post :verify, params: { product_permalink: product.unique_permalink, license_key: original_purchase.license.serial }
      expect(response.code.to_i).to eq(200)
      original_purchase.reload
      expect(response.parsed_body["purchase"]["email"]).to eq original_purchase.email
      expect(response.parsed_body["purchase"]["subscription_cancelled_at"]).to eq nil
      expect(response.parsed_body["purchase"]["subscription_failed_at"]).to eq nil
    end

    it "returns an error response when a user provides a non existent product" do
      post :verify, params: { product_permalink: @product.unique_permalink + "invalid", license_key: "Does not exist" }
      expect(response.code.to_i).to eq(404)
      expect(response.parsed_body).to eq({
        success: false,
        message: "That license does not exist for the provided product."
      }.as_json)
    end

    it "returns successful response for case-insensitive product_permalink param" do
      @product.update!(custom_permalink: "custom")
      post :verify, params: { product_permalink: "CUSTOM", license_key: @purchase.license.serial }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include({ "success" => true })
    end

    describe "legacy params" do
      it "returns successful response when product permalink is passed via `id` param" do
        post :verify, params: { id: @product.unique_permalink, link_id: "invalid", product_permalink: "invalid", license_key: @purchase.license.serial }

        expect(response).to have_http_status(:ok)
        @purchase.reload
        expect(response.parsed_body).to eq({
          success: true,
          uses: 1,
          purchase: {
            id: ObfuscateIds.encrypt(@purchase.id),
            product_name: @product.name,
            created_at: @purchase.created_at,
            variants: "",
            custom_fields: [],
            quantity: 1,
            refunded: false,
            chargebacked: false,
            email: @purchase.email,
            seller_id: ObfuscateIds.encrypt(@purchase.seller.id),
            product_id: ObfuscateIds.encrypt(@product.id),
            permalink: @product.general_permalink,
            product_permalink: @product.long_url,
            short_product_id: @product.unique_permalink,
            price: @purchase.price_cents,
            currency: @product.price_currency_type,
            order_number: @purchase.external_id_numeric,
            sale_id: ObfuscateIds.encrypt(@purchase.id),
            sale_timestamp: @purchase.created_at,
            license_key: @purchase.license.serial,
            is_gift_receiver_purchase: false,
            disputed: false,
            dispute_won: false,
            gumroad_fee: @purchase.fee_cents,
            discover_fee_charged: @purchase.was_discover_fee_charged,
            can_contact: @purchase.can_contact,
            referrer: @purchase.referrer,
            card: {
              bin: nil,
              expiry_month: @purchase.card_expiry_month,
              expiry_year: @purchase.card_expiry_year,
              type: @purchase.card_type,
              visual: @purchase.card_visual,
            }
          }
        }.as_json)
      end

      it "returns successful response when product permalink is passed via `link_id` param" do
        post :verify, params: { link_id: @product.unique_permalink, product_permalink: "invalid", license_key: @purchase.license.serial }

        expect(response).to have_http_status(:ok)
        @purchase.reload
        expect(response.parsed_body).to eq({
          success: true,
          uses: 1,
          purchase: {
            id: ObfuscateIds.encrypt(@purchase.id),
            product_name: @product.name,
            created_at: @purchase.created_at,
            variants: "",
            custom_fields: [],
            quantity: 1,
            refunded: false,
            chargebacked: false,
            email: @purchase.email,
            seller_id: ObfuscateIds.encrypt(@purchase.seller.id),
            product_id: ObfuscateIds.encrypt(@product.id),
            permalink: @product.general_permalink,
            product_permalink: @product.long_url,
            short_product_id: @product.unique_permalink,
            price: @purchase.price_cents,
            currency: @product.price_currency_type,
            order_number: @purchase.external_id_numeric,
            sale_id: ObfuscateIds.encrypt(@purchase.id),
            sale_timestamp: @purchase.created_at,
            license_key: @purchase.license.serial,
            is_gift_receiver_purchase: false,
            disputed: false,
            dispute_won: false,
            gumroad_fee: @purchase.fee_cents,
            discover_fee_charged: @purchase.was_discover_fee_charged,
            can_contact: @purchase.can_contact,
            referrer: @purchase.referrer,
            card: {
              bin: nil,
              expiry_month: @purchase.card_expiry_month,
              expiry_year: @purchase.card_expiry_year,
              type: @purchase.card_type,
              visual: @purchase.card_visual,
            }
          }
        }.as_json)
      end
    end

    context "when product_id is blank" do
      before do
        create(:product, custom_permalink: @product.unique_permalink)
      end

      context "when product_id check is not skipped for the product" do
        context "when product_id param is enforced for the license verification of the product" do
          before do
            @redis_namespace = Redis::Namespace.new(:license_verifications, redis: $redis)
          end

          context "when product's created_at is after the set timestamp" do
            before do
              $redis.set(RedisKey.force_product_id_timestamp, @product.created_at - 1.day)
            end

            it "responds with error" do
              post :verify, params: { product_permalink: @product.unique_permalink, license_key: @purchase.license.serial }

              expect(response).to have_http_status(:internal_server_error)
              message = "The 'product_id' parameter is required to verify the license for this product. "
              message += "Please set 'product_id' to '#{@product.external_id}' in the request."
              expect(response.parsed_body).to eq({
                success: false,
                message:
              }.as_json)
            end

            context "when the permalink doesn't match with the product" do
              it "responds with error without double rendering the response" do
                post :verify, params: { product_permalink: create(:product).unique_permalink, license_key: @purchase.license.serial }

                expect(response).to have_http_status(:internal_server_error)
                message = "The 'product_id' parameter is required to verify the license for this product. "
                message += "Please set 'product_id' to '#{@product.external_id}' in the request."
                expect(response.parsed_body).to eq({
                  success: false,
                  message:
                }.as_json)
              end
            end
          end

          context "when product's created_at is before the set timestamp" do
            before do
              $redis.set(RedisKey.force_product_id_timestamp, @product.created_at + 1.day)
            end

            it "verifies the license" do
              post :verify, params: { product_permalink: @product.unique_permalink, license_key: @purchase.license.serial }

              expect(response).to be_successful
              expect(response.parsed_body).to include({ "success" => true })
            end
          end
        end
      end

      context "when the product_id check is skipped for the product" do
        before do
          redis_namespace = Redis::Namespace.new(:license_verifications, redis: $redis)
          redis_namespace.set("skip_product_id_check_#{@product.id}", true)
        end

        it "verifies the license" do
          post :verify, params: { product_permalink: @product.unique_permalink, license_key: @purchase.license.serial }

          expect(response).to be_successful
          expect(response.parsed_body).to include({ "success" => true })
        end
      end
    end

    context "when product_id param is not blank" do
      it "verifies the license" do
        post :verify, params: { product_id: @product.external_id, license_key: @purchase.license.serial }

        expect(response).to be_successful
        expect(response.parsed_body).to include({ "success" => true })
      end
    end
  end

  describe "PUT 'decrement_uses_count'" do
    shared_examples_for "decrement uses count" do |product_identifier_key, product_identifier_value|
      before do
        @product_identifier = { product_identifier_key => @product.send(product_identifier_value) }
      end

      context "unauthorized" do
        it "raises 401 error when not authorized" do
          put :decrement_uses_count, params: { license_key: @purchase.license.serial }.merge(@product_identifier)
          expect(response.code.to_i).to eq(401)
        end
      end

      context "authorized with the edit_products scope" do
        before do
          @app = create(:oauth_application, owner: create(:user))
          @token = create("doorkeeper/access_token", application: @app,
                                                     resource_owner_id: @product.user.id,
                                                     scopes: "edit_products")
        end


        it "decreases the license uses count and returns the correct json when a valid product and license key are provided" do
          @license.increment!(:uses)
          put :decrement_uses_count, params: { access_token: @token.token, license_key: @purchase.license.serial }.merge(@product_identifier)
          expect(response.code.to_i).to eq(200)
          @purchase.reload
          expect(response.parsed_body).to eq({
            success: true,
            uses: 0,
            purchase: {
              id: ObfuscateIds.encrypt(@purchase.id),
              product_name: @product.name,
              created_at: @purchase.created_at,
              variants: "",
              custom_fields: [],
              quantity: 1,
              refunded: false,
              chargebacked: false,
              email: @purchase.email,
              seller_id: ObfuscateIds.encrypt(@purchase.seller.id),
              product_id: ObfuscateIds.encrypt(@product.id),
              permalink: @product.general_permalink,
              product_permalink: @product.long_url,
              short_product_id: @product.unique_permalink,
              price: @purchase.price_cents,
              currency: @product.price_currency_type,
              order_number: @purchase.external_id_numeric,
              sale_id: ObfuscateIds.encrypt(@purchase.id),
              sale_timestamp: @purchase.created_at,
              license_key: @purchase.license.serial,
              is_gift_receiver_purchase: false,
              disputed: false,
              dispute_won: false,
              gumroad_fee: @purchase.fee_cents,
              discover_fee_charged: @purchase.was_discover_fee_charged,
              can_contact: @purchase.can_contact,
              referrer: @purchase.referrer,
              card: {
                bin: nil,
                expiry_month: @purchase.card_expiry_month,
                expiry_year: @purchase.card_expiry_year,
                type: @purchase.card_type,
                visual: @purchase.card_visual,
              }
            }
          }.as_json)
        end

        it "does not decrease the license uses count if the uses count is 0" do
          put :decrement_uses_count, params: { access_token: @token.token, license_key: @purchase.license.serial }.merge(@product_identifier)
          expect(response.code.to_i).to eq(200)
          expect(response.parsed_body["uses"]).to eq(0)
        end

        it "returns a 404 error if the license user is not the current resource owner" do
          token = create("doorkeeper/access_token", application: @app,
                                                    resource_owner_id: create(:user).id,
                                                    scopes: "edit_products")
          put :decrement_uses_count, params: { access_token: token.token, license_key: @purchase.license.serial }.merge(@product_identifier)
          expect(response.code.to_i).to eq(404)
        end
      end
    end

    it_behaves_like "decrement uses count", :product_permalink, :unique_permalink
    it_behaves_like "decrement uses count", :product_permalink, :custom_permalink
    it_behaves_like "decrement uses count", :product_id, :external_id
  end
end
