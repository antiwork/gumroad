# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::UpsellsController do
  before do
    @user = create(:user, :eligible_for_service_products)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product_with_digital_versions, user: @user, price_cents: 1000)
    @other_product = create(:product_with_digital_versions, user: @user, price_cents: 500)
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "returns an empty list when there are no upsells" do
        get @action, params: @params
        expect(response.parsed_body["upsells"]).to eq([])
      end

      it "returns the seller's upsells" do
        upsell = create(:upsell, seller: @user, product: @product, name: "Upsell")
        get @action, params: @params

        result = response.parsed_body.deep_symbolize_keys
        expect(result).to eq(success: true, upsells: [upsell].as_json(api_scopes: ["view_public"]))
      end

      it "excludes content upsells" do
        create(:upsell, seller: @user, product: @product, name: "Standalone")
        create(:upsell, seller: @user, product: @product, name: nil, is_content_upsell: true, cross_sell: true)

        get @action, params: @params
        expect(response.parsed_body["upsells"].map { _1["name"] }).to eq(["Standalone"])
      end

      it "excludes deleted upsells" do
        create(:upsell, seller: @user, product: @product, name: "Alive")
        create(:upsell, seller: @user, product: @product, name: "Dead", deleted_at: Time.current)

        get @action, params: @params
        expect(response.parsed_body["upsells"].map { _1["name"] }).to eq(["Alive"])
      end

      it "does not return another seller's upsells" do
        create(:upsell, name: "Theirs")
        get @action, params: @params
        expect(response.parsed_body["upsells"]).to eq([])
      end
    end

    it "grants access with the account scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      get @action, params: @params.merge(access_token: token.token)
      expect(response).to be_successful
    end
  end

  describe "GET 'show'" do
    before do
      @upsell = create(:upsell, seller: @user, product: @product, name: "Upsell")
      @action = :show
      @params = { id: @upsell.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        get @action, params: @params.merge(id: "#{@params[:id]}++")
        expect(response.parsed_body).to eq({ success: false, message: "The upsell was not found." }.as_json)
      end

      it "returns the correct response" do
        get @action, params: @params

        result = response.parsed_body.deep_symbolize_keys
        expect(result).to eq(success: true, upsell: @upsell.as_json(api_scopes: ["view_public"]))
      end

      it "does not return a content upsell" do
        content_upsell = create(:upsell, seller: @user, product: @product, name: nil, is_content_upsell: true, cross_sell: true)
        get @action, params: @params.merge(id: content_upsell.external_id)
        expect(response.parsed_body).to eq({ success: false, message: "The upsell was not found." }.as_json)
      end

      it "does not return another seller's upsell" do
        other = create(:upsell, name: "Theirs")
        get @action, params: @params.merge(id: other.external_id)
        expect(response.parsed_body).to eq({ success: false, message: "The upsell was not found." }.as_json)
      end
    end
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @params = {
        name: "Course upsell",
        text: "Complete course upsell",
        description: "You'll enjoy a range of exclusive features.",
        cross_sell: false,
        product_id: @product.external_id,
        upsell_variants: [{ selected_variant_id: @product.alive_variants.first.external_id, offered_variant_id: @product.alive_variants.second.external_id }],
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "creates an upsell with a version change" do
        expect do
          post @action, params: @params, as: :json
        end.to change { @user.upsells.count }.by(1)

        upsell = @user.upsells.last
        expect(response.parsed_body["success"]).to eq(true)
        expect(upsell.name).to eq("Course upsell")
        expect(upsell.text).to eq("Complete course upsell")
        expect(upsell.cross_sell).to eq(false)
        expect(upsell.product).to eq(@product)
        expect(upsell.upsell_variants.length).to eq(1)
        expect(upsell.upsell_variants.first.selected_variant).to eq(@product.alive_variants.first)
        expect(upsell.upsell_variants.first.offered_variant).to eq(@product.alive_variants.second)
      end

      it "returns the created upsell as the response" do
        post @action, params: @params, as: :json

        result = response.parsed_body.deep_symbolize_keys
        expect(result).to eq(success: true, upsell: @user.upsells.last.as_json(api_scopes: ["edit_products"]))
      end

      it "creates a cross-sell with an offer code and selected products" do
        post @action, params: @params.merge(
          cross_sell: true,
          replace_selected_products: true,
          upsell_variants: [],
          variant_id: @product.alive_variants.first.external_id,
          product_ids: [@other_product.external_id],
          offer_code: { amount_cents: 200 },
        ), as: :json

        upsell = @user.upsells.last
        expect(response.parsed_body["success"]).to eq(true)
        expect(upsell.cross_sell).to eq(true)
        expect(upsell.replace_selected_products).to eq(true)
        expect(upsell.variant).to eq(@product.alive_variants.first)
        expect(upsell.selected_products).to eq([@other_product])
        expect(upsell.offer_code.amount_cents).to eq(200)
        expect(upsell.offer_code.amount_percentage).to be_nil
        expect(upsell.offer_code.products).to eq([@product])
      end

      it "creates a universal cross-sell with a percentage offer code" do
        post @action, params: @params.merge(
          cross_sell: true,
          universal: true,
          upsell_variants: [],
          offer_code: { amount_percentage: 25 },
        ), as: :json

        upsell = @user.upsells.last
        expect(response.parsed_body["success"]).to eq(true)
        expect(upsell.universal).to eq(true)
        expect(upsell.offer_code.amount_percentage).to eq(25)
        expect(upsell.offer_code.amount_cents).to be_nil
      end

      it "marks the seller as a CLI user when the request comes from the CLI" do
        request.user_agent = "gumroad-cli/1.0"
        post @action, params: @params, as: :json
        expect(@user.reload.has_used_cli?).to be(true)
      end

      it "returns a validation error when the variant belongs to another product" do
        foreign_variant = create(:product_with_digital_versions).alive_variants.first

        expect do
          post @action, params: @params.merge(upsell_variants: [], cross_sell: true, variant_id: foreign_variant.external_id, product_ids: [@other_product.external_id]), as: :json
        end.not_to change { @user.upsells.count }

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("The offered variant must belong to the offered product.")
      end

      it "returns a validation error, not a server error, when an upsell variant belongs to another product" do
        foreign_variant = create(:product_with_digital_versions).alive_variants.first

        expect do
          post @action, params: @params.merge(upsell_variants: [{ selected_variant_id: foreign_variant.external_id, offered_variant_id: foreign_variant.external_id }]), as: :json
        end.not_to change { @user.upsells.count }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to be_present
      end

      it "returns an error when a call is offered as an upsell" do
        call = create(:call_product, user: @user)
        expect do
          post @action, params: @params.merge(product_id: call.external_id, upsell_variants: []), as: :json
        end.not_to change { @user.upsells.count }

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Calls cannot be offered as upsells.")
      end

      it "returns an error when the product does not exist" do
        post @action, params: @params.merge(product_id: "nonexistent", upsell_variants: []), as: :json
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("The product, variant, or offer referenced by an external ID could not be found.")
      end

      it "does not create an upsell for another seller's product" do
        foreign_product = create(:product)
        post @action, params: @params.merge(product_id: foreign_product.external_id, upsell_variants: []), as: :json
        expect(response.parsed_body["success"]).to eq(false)
        expect(@user.upsells.count).to eq(0)
      end
    end
  end

  describe "PUT 'update'" do
    before do
      @upsell = create(:upsell, seller: @user, product: @product, name: "Upsell", cross_sell: true)
      @action = :update
      @params = { id: @upsell.external_id, product_id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        put @action, params: @params.merge(id: "#{@params[:id]}++"), as: :json
        expect(response.parsed_body).to eq({ success: false, message: "The upsell was not found." }.as_json)
      end

      it "updates the upsell's text fields" do
        expect do
          put @action, params: @params.merge(name: "Renamed", text: "New text", description: "New description"), as: :json
          @upsell.reload
        end.to change { @upsell.name }.from("Upsell").to("Renamed")
          .and change { @upsell.text }.to("New text")
          .and change { @upsell.description }.to("New description")

        expect(response.parsed_body["success"]).to eq(true)
      end

      it "adds and updates an offer code" do
        expect do
          put @action, params: @params.merge(offer_code: { amount_cents: 200 }), as: :json
          @upsell.reload
        end.to change { @upsell.offer_code&.amount_cents }.from(nil).to(200)

        expect do
          put @action, params: @params.merge(offer_code: { amount_percentage: 10 }), as: :json
          @upsell.reload
        end.to change { @upsell.offer_code.amount_cents }.from(200).to(nil)
          .and change { @upsell.offer_code.amount_percentage }.from(nil).to(10)
      end

      it "preserves associations omitted from a partial update" do
        upsell = create(:upsell, seller: @user, product: @product, name: "Full", cross_sell: true,
                                 variant: @product.alive_variants.first,
                                 offer_code: create(:offer_code, products: [@product], user: @user, amount_cents: 300))
        upsell.selected_products = [@other_product]

        put @action, params: { id: upsell.external_id, name: "Renamed", access_token: @token.token }, as: :json
        upsell.reload

        expect(response.parsed_body["success"]).to eq(true)
        expect(upsell.name).to eq("Renamed")
        expect(upsell.product).to eq(@product)
        expect(upsell.variant).to eq(@product.alive_variants.first)
        expect(upsell.selected_products).to eq([@other_product])
        expect(upsell.offer_code&.amount_cents).to eq(300)
      end

      it "preserves upsell variants omitted from a partial update" do
        upsell = create(:upsell, seller: @user, product: @product, name: "Versioned", cross_sell: false)
        create(:upsell_variant, upsell:, selected_variant: @product.alive_variants.first, offered_variant: @product.alive_variants.second)

        put @action, params: { id: upsell.external_id, paused: true, access_token: @token.token }, as: :json
        upsell.reload

        expect(response.parsed_body["success"]).to eq(true)
        expect(upsell.paused).to eq(true)
        expect(upsell.upsell_variants.alive.count).to eq(1)
      end

      it "clears an association when an explicit empty value is sent" do
        upsell = create(:upsell, seller: @user, product: @product, name: "Has variant", cross_sell: true, variant: @product.alive_variants.first)

        put @action, params: { id: upsell.external_id, product_id: @product.external_id, variant_id: "", access_token: @token.token }, as: :json
        upsell.reload

        expect(response.parsed_body["success"]).to eq(true)
        expect(upsell.variant).to be_nil
      end

      it "drops version mappings tied to the old product when the product changes" do
        upsell = create(:upsell, seller: @user, product: @product, name: "Versioned", cross_sell: false)
        create(:upsell_variant, upsell:, selected_variant: @product.alive_variants.first, offered_variant: @product.alive_variants.second)

        put @action, params: { id: upsell.external_id, product_id: @other_product.external_id, access_token: @token.token }, as: :json
        upsell.reload

        expect(response.parsed_body["success"]).to eq(true)
        expect(upsell.product).to eq(@other_product)
        expect(upsell.upsell_variants.alive).to be_empty
      end

      it "drops version mappings when a version upsell is converted to a cross-sell" do
        upsell = create(:upsell, seller: @user, product: @product, name: "Versioned", cross_sell: false)
        create(:upsell_variant, upsell:, selected_variant: @product.alive_variants.first, offered_variant: @product.alive_variants.second)

        put @action, params: { id: upsell.external_id, cross_sell: true, product_ids: [@other_product.external_id], access_token: @token.token }, as: :json
        upsell.reload

        expect(response.parsed_body["success"]).to eq(true)
        expect(upsell.cross_sell).to eq(true)
        expect(upsell.upsell_variants.alive).to be_empty
      end

      it "returns the updated upsell as the response" do
        put @action, params: @params.merge(name: "Renamed"), as: :json

        result = response.parsed_body.deep_symbolize_keys
        expect(result).to eq(success: true, upsell: @upsell.reload.as_json(api_scopes: ["edit_products"]))
      end

      it "returns a validation error when the variant belongs to another product" do
        foreign_variant = create(:product_with_digital_versions).alive_variants.first
        put @action, params: @params.merge(variant_id: foreign_variant.external_id), as: :json

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("The offered variant must belong to the offered product.")
      end

      it "cannot update another seller's upsell" do
        other = create(:upsell, name: "Theirs")
        put @action, params: @params.merge(id: other.external_id), as: :json
        expect(response.parsed_body).to eq({ success: false, message: "The upsell was not found." }.as_json)
        expect(other.reload.name).to eq("Theirs")
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @upsell = create(:upsell, seller: @user, product: @product, name: "Upsell", cross_sell: true, offer_code: create(:offer_code, products: [@product], user: @user))
      @upsell_variant = create(:upsell_variant, upsell: @upsell, selected_variant: @product.alive_variants.first, offered_variant: @product.alive_variants.second)
      @action = :destroy
      @params = { id: @upsell.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "marks the upsell, its offer code, and its variants as deleted" do
        delete @action, params: @params

        expect(response.parsed_body).to eq({ success: true, message: "The upsell was deleted successfully." }.as_json)
        expect(@upsell.reload.deleted_at).to be_present
        expect(@upsell_variant.reload.deleted_at).to be_present
        expect(@upsell.offer_code.reload.deleted_at).to be_present
      end

      it "fails gracefully on bad id" do
        delete @action, params: @params.merge(id: "#{@params[:id]}++")
        expect(response.parsed_body).to eq({ success: false, message: "The upsell was not found." }.as_json)
      end
    end
  end
end
