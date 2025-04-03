# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::OfferCodesController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "GET 'index'" do
    before do
      @product = create(:product, user: @user, description: "des")
      @action = :index
      @params = { link_id: @product.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "shows the 0 custom offers" do
        get @action, params: @params
        expect(response.parsed_body["offer_codes"]).to eq([])
      end

      it "returns a single offer code" do
        offer_code = create(:offer_code, products: [@product])
        get @action, params: @params

        result = response.parsed_body.deep_symbolize_keys

        expect(result).to eq(success: true, offer_codes: [offer_code].as_json(api_scopes: ["view_public"]))
      end
    end
  end

  describe "POST 'create'" do
    before do
      @product = create(:product, user: @user, description: "des", price_cents: 10_000)
      @new_offer_code_params = { name: "hi", amount_off: 31, max_purchase_count: 5 }

      @action = :create
      @params = { link_id: @product.external_id }.merge(@new_offer_code_params)
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      describe "incorrect parameters" do
        it "returns error message" do
          post :create, params: @params.merge(amount_off: nil)
          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["message"]).to eq("You are missing required offer code parameters. Please refer to " \
                                               "https://gumroad.com/api#offer-codes for the correct parameters.")
        end
      end

      it "creates a new cents offer code" do
        post @action, params: @params.merge(offer_type: "cents")

        expect(@product.reload.offer_codes.alive.count).to eq 1
        offer_code = @product.offer_codes.alive.first
        expect(offer_code.code).to eq @new_offer_code_params[:name]
        expect(offer_code.amount_cents).to eq @new_offer_code_params[:amount_off]
        expect(offer_code.amount_percentage).to be(nil)
        expect(offer_code.max_purchase_count).to eq @new_offer_code_params[:max_purchase_count]
        expect(offer_code.currency_type).to eq @product.price_currency_type
        expect(offer_code.universal?).to eq false
        expect(offer_code.products).to match_array(@product)
      end

      it "creates a new percent offer code" do
        post @action, params: @params.merge(offer_type: "percent")

        expect(@product.reload.offer_codes.alive.count).to eq(1)
        expect(@product.offer_codes.alive.first.code).to eq @new_offer_code_params[:name]
        expect(@product.offer_codes.alive.first.amount_percentage).to eq @new_offer_code_params[:amount_off]
        expect(@product.offer_codes.alive.first.amount_cents).to be(nil)
        expect(@product.offer_codes.alive.first.max_purchase_count).to eq @new_offer_code_params[:max_purchase_count]
      end

      it "creates a new cents offer code if amount_cents is passed in" do
        post @action, params: @params.merge(offer_type: "cents", amount_cents: 50)

        expect(@product.reload.offer_codes.alive.count).to eq 1
        expect(@product.offer_codes.alive.first.code).to eq @new_offer_code_params[:name]
        expect(@product.offer_codes.alive.first.amount_cents).to eq 50
        expect(@product.offer_codes.alive.first.amount_percentage).to be(nil)
        expect(@product.offer_codes.alive.first.max_purchase_count).to eq @new_offer_code_params[:max_purchase_count]
        expect(@product.offer_codes.alive.first.currency_type).to eq @product.price_currency_type
      end

      it "creates a percent offer code by ignoring amount_cents and using amount_off" do
        post @action, params: @params.merge(offer_type: "percent", amount_cents: 50)

        expect(@product.reload.offer_codes.alive.count).to eq(1)
        expect(@product.offer_codes.alive.first.code).to eq @new_offer_code_params[:name]
        expect(@product.offer_codes.alive.first.amount_percentage).to eq 31
        expect(@product.offer_codes.alive.first.amount_cents).to be(nil)
        expect(@product.offer_codes.alive.first.max_purchase_count).to eq @new_offer_code_params[:max_purchase_count]
      end

      it "creates a new universal percent offer code" do
        post @action, params: @params.merge(offer_type: "percent", universal: "true")

        expect(@product.reload.offer_codes.alive.count).to eq 0
        expect(@product.user.offer_codes.universal_with_matching_currency(@product.price_currency_type).alive.count).to eq 1
        offer_code = @product.user.offer_codes.universal_with_matching_currency(@product.price_currency_type).alive.first
        expect(offer_code.code).to eq @new_offer_code_params[:name]
        expect(offer_code.amount_percentage).to eq @new_offer_code_params[:amount_off]
        expect(offer_code.amount_cents).to be(nil)
        expect(offer_code.max_purchase_count).to eq @new_offer_code_params[:max_purchase_count]
        expect(offer_code.universal?).to be(true)
        expect(offer_code.products).to be_empty
      end

      it "returns the right response" do
        post @action, params: @params

        result = response.parsed_body.deep_symbolize_keys
        expect(result).to eq(success: true, offer_code: @product.reload.offer_codes.alive.first.as_json(api_scopes: ["edit_products"]))
      end

      describe "there is already an offer code" do
        before do
          @first_offer_code = create(:offer_code, products: [@product])
        end

        it "persists a new offer code" do
          post @action, params: @params

          expect(@product.reload.offer_codes.alive.count).to eq(2)
          expect(@product.offer_codes.alive.first).to eq(@first_offer_code)
          expect(@product.offer_codes.alive.second.code).to eq(@new_offer_code_params[:name])
          expect(@product.offer_codes.alive.second.amount_cents).to eq(@new_offer_code_params[:amount_off])
          expect(@product.offer_codes.alive.second.max_purchase_count).to eq(@new_offer_code_params[:max_purchase_count])
        end
      end
    end
  end

  describe "GET 'show'" do
    before do
      @product = create(:product, user: @user, description: "des")
      @offer_code = create(:offer_code, code: "50_OFF", user: @user, products: [@product])

      @action = :show
      @params = {
        link_id: @product.external_id,
        id: @offer_code.external_id
      }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        get @action, params: @params.merge(id: @params[:id] + "++")
        expect(response.parsed_body).to eq({
          success: false,
          message: "The offer_code was not found."
        }.as_json)
      end

      it "returns the correct response" do
        get @action, params: @params

        result = response.parsed_body.deep_symbolize_keys
        expect(result).to eq(success: true, offer_code: @product.reload.offer_codes.alive.first.as_json(api_scopes: ["view_public"]))
        # For compatibility reasons, `code` is returned as `name`
        expect(result[:offer_code][:name]).to eq("50_OFF")
      end
    end
  end

  describe "PUT 'update'" do
    before do
      @product = create(:product, user: @user, description: "des", price_cents: 10_000)
      @offer_code = create(:offer_code, user: @user, products: [@product], code: "99_OFF", amount_cents: 9900, max_purchase_count: 69)
      @new_offer_code_params = { max_purchase_count: 96 }

      @action = :update
      @params = {
        link_id: @product.external_id,
        id: @offer_code.external_id
      }.merge @new_offer_code_params
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "fails gracefully on bad id" do
        put @action, params: @params.merge(id: @params[:id] + "++")
        expect(response.parsed_body).to eq({
          success: false,
          message: "The offer_code was not found."
        }.as_json)
      end

      it "updates offer code max_purchase_count" do
        put @action, params: @params
        expect(@product.reload.offer_codes.alive.count).to eq(1)
        expect(@product.offer_codes.alive.first.max_purchase_count).to eq(@new_offer_code_params[:max_purchase_count])
      end

      it "returns the right response" do
        put @action, params: @params

        result = response.parsed_body.deep_symbolize_keys
        expect(result).to eq(success: true, offer_code: @product.reload.offer_codes.alive.first.as_json(api_scopes: ["edit_products"]))
      end

      it "does not update the code or amount_cents" do
        put @action, params: @params

        expect(@product.reload.offer_codes.alive.count).to eq(1)
        expect(@product.offer_codes.alive.first.code).to eq("99_OFF")
        expect(@product.offer_codes.alive.first.amount_cents).to eq(9900)
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @product = create(:product, user: @user, description: "des", price_cents: 10_000)
      @offer_code = create(:offer_code, user: @user, products: [@product], code: "99_OFF", amount_cents: 9900)
      @action = :destroy
      @params = { link_id: @product.external_id, id: @offer_code.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "works if offer code id passed in" do
        delete @action, params: @params
        expect(@product.reload.offer_codes.alive.count).to eq 0
      end

      it "deletes the universal offer code" do
        universal_offer = create(:universal_offer_code, user: @product.user, code: "uni1", amount_cents: 9900)
        expect(@product.user.offer_codes.universal_with_matching_currency(@product.price_currency_type).alive.count).to eq 1

        delete @action, params: @params.merge(id: universal_offer.external_id)
        expect(@product.user.offer_codes.universal_with_matching_currency(@product.price_currency_type).alive.count).to eq 0
      end

      it "fails gracefully on bad id" do
        delete @action, params: @params.merge(id: @params[:id] + "++")
        expect(response.parsed_body).to eq({
          success: false,
          message: "The offer_code was not found."
        }.as_json)
      end

      it "returns the right response" do
        delete @action, params: @params
        expect(response.parsed_body).to eq({
          success: true,
          message: "The offer_code was deleted successfully."
        }.as_json)
      end
    end
  end
end
