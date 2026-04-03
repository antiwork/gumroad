# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::BundleContentsController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "PUT 'update'" do
    before do
      @bundle = create(:product, user: @user, is_bundle: true)
      @bundled_product = create(:product, user: @user, name: "Bundled Product")
      @action = :update
      @params = {
        link_id: @bundle.external_id,
        products: [
          { product_id: @bundled_product.external_id, quantity: 1, position: 0 }
        ]
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "assigns products to a bundle" do
        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)

        @bundle.reload
        expect(@bundle.bundle_products.alive.count).to eq(1)

        bundle_product = @bundle.bundle_products.alive.first
        expect(bundle_product.product).to eq(@bundled_product)
        expect(bundle_product.quantity).to eq(1)
        expect(bundle_product.position).to eq(0)
      end

      it "updates quantity, selected variant, and position" do
        product_with_variants = create(:product_with_digital_versions, user: @user)
        variant = product_with_variants.variant_categories.first.variants.first

        @params[:products] = [
          { product_id: product_with_variants.external_id, variant_id: variant.external_id, quantity: 3, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful

        bundle_product = @bundle.bundle_products.alive.first
        expect(bundle_product.product).to eq(product_with_variants)
        expect(bundle_product.variant).to eq(variant)
        expect(bundle_product.quantity).to eq(3)
        expect(bundle_product.position).to eq(0)
      end

      it "removes products omitted from the request" do
        existing_bp = @bundle.bundle_products.create!(product: @bundled_product, quantity: 1, position: 0)
        another_product = create(:product, user: @user, name: "Another Product")

        @params[:products] = [
          { product_id: another_product.external_id, quantity: 2, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(existing_bp.reload.deleted_at).to be_present
        expect(@bundle.bundle_products.alive.count).to eq(1)
        expect(@bundle.bundle_products.alive.first.product).to eq(another_product)
      end

      it "rejects invalid bundled products with validation errors" do
        other_user = create(:user)
        other_product = create(:product, user: other_user)

        @params[:products] = [
          { product_id: other_product.external_id, quantity: 1, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("The product must belong to the bundle's seller")
      end

      it "rejects non-bundle products" do
        regular_product = create(:product, user: @user)
        @params[:link_id] = regular_product.external_id

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("This product is not a bundle.")
      end

      it "rejects bundles as bundled products" do
        another_bundle = create(:product, user: @user, is_bundle: true)

        @params[:products] = [
          { product_id: another_bundle.external_id, quantity: 1, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("A bundle product cannot be added to a bundle")
      end

      it "rejects subscription products as bundled products" do
        subscription = create(:product, user: @user, is_recurring_billing: true, subscription_duration: :monthly)

        @params[:products] = [
          { product_id: subscription.external_id, quantity: 1, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("A subscription product cannot be added to a bundle")
      end

      it "rejects call products as bundled products" do
        @user.update!(created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
        call_product = create(:call_product, user: @user)

        @params[:products] = [
          { product_id: call_product.external_id, quantity: 1, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("A call product cannot be added to a bundle")
      end

      it "returns the updated product in the response" do
        put @action, params: @params

        expect(response).to be_successful
        product_json = response.parsed_body["product"]
        expect(product_json).to be_present
        expect(product_json["id"]).to eq(@bundle.external_id)
        expect(product_json["name"]).to eq(@bundle.name)
      end

      it "clears all products from an unpublished bundle" do
        @bundle.update!(purchase_disabled_at: Time.current)
        @bundle.bundle_products.create!(product: @bundled_product, quantity: 1, position: 0)
        @params.delete(:products)

        put @action, params: @params

        expect(response).to be_successful
        expect(@bundle.bundle_products.alive.count).to eq(0)
      end

      it "rejects clearing all products from a published bundle" do
        @bundle.bundle_products.create!(product: @bundled_product, quantity: 1, position: 0)
        @params.delete(:products)

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("Bundles must have at least one product")
      end

      it "handles multiple products with correct positions" do
        product2 = create(:product, user: @user, name: "Product 2")
        product3 = create(:product, user: @user, name: "Product 3")

        @params[:products] = [
          { product_id: @bundled_product.external_id, quantity: 1, position: 0 },
          { product_id: product2.external_id, quantity: 2, position: 1 },
          { product_id: product3.external_id, quantity: 1, position: 2 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(@bundle.bundle_products.alive.count).to eq(3)
        expect(@bundle.bundle_products.alive.in_order.map(&:product)).to eq([@bundled_product, product2, product3])
        expect(@bundle.bundle_products.alive.find_by(product: product2).quantity).to eq(2)
      end

      it "grants access with the account scope" do
        token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
        @params[:access_token] = token.token

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
      end

      it "rejects zero quantity" do
        @params[:products] = [
          { product_id: @bundled_product.external_id, quantity: 0, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Quantity must be an integer greater than 0.")
      end

      it "rejects negative quantity" do
        @params[:products] = [
          { product_id: @bundled_product.external_id, quantity: -1, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Quantity must be an integer greater than 0.")
      end

      it "rolls back all changes when one product is invalid" do
        other_user = create(:user)
        other_product = create(:product, user: other_user)

        @params[:products] = [
          { product_id: @bundled_product.external_id, quantity: 1, position: 0 },
          { product_id: other_product.external_id, quantity: 1, position: 1 }
        ]

        put @action, params: @params

        expect(response.parsed_body["success"]).to be(false)
        expect(@bundle.bundle_products.alive.count).to eq(0)
      end

      it "rejects malformed products param" do
        @params[:products] = { "0" => { product_id: @bundled_product.external_id, quantity: 1, position: 0 } }

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Products must be an array.")
      end

      it "rejects nonexistent product IDs" do
        @params[:products] = [
          { product_id: "nonexistent_id", quantity: 1, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("One or more products could not be found.")
      end

      it "rejects bundles owned by another seller" do
        other_user = create(:user)
        other_bundle = create(:product, user: other_user, is_bundle: true)
        other_product = create(:product, user: other_user)
        @params[:link_id] = other_bundle.external_id
        @params[:products] = [
          { product_id: other_product.external_id, quantity: 1, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("The product was not found.")
        expect(other_bundle.bundle_products.alive.count).to eq(0)
      end

      it "rejects versioned products without a variant" do
        product_with_variants = create(:product_with_digital_versions, user: @user)

        @params[:products] = [
          { product_id: product_with_variants.external_id, quantity: 1, position: 0 }
        ]

        put @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("Bundle product must have variant specified for versioned product")
      end
    end
  end
end
