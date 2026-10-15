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

    it "grants access with the account scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      get @action, params: @params.merge(access_token: token.token)
      expect(response).to be_successful
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

      it "creates a universal auto-applied code with a sale label" do
        post @action, params: @params.merge(universal: "true", auto_apply: "true", sale_label: "Black Friday")

        expect(response.parsed_body["success"]).to eq(true)
        code = @user.offer_codes.alive.last
        expect(code).to have_attributes(auto_apply: true, sale_label: "Black Friday", universal: true)
        expect(response.parsed_body["offer_code"]).to include("auto_apply" => true, "sale_label" => "Black Friday")
      end

      it "accepts a JSON boolean for auto_apply" do
        post @action, params: @params.merge(universal: true, auto_apply: true, sale_label: "Black Friday"), as: :json

        expect(response.parsed_body["success"]).to eq(true)
        code = @user.offer_codes.alive.last
        expect(code).to have_attributes(auto_apply: true, sale_label: "Black Friday", universal: true)
        expect(response.parsed_body["offer_code"]).to include("auto_apply" => true, "sale_label" => "Black Friday")
      end

      it "creates a universal percent code from a JSON boolean" do
        post @action, params: @params.merge(offer_type: "percent", universal: true), as: :json

        expect(response.parsed_body["success"]).to eq(true)
        code = @user.offer_codes.alive.last
        expect(code).to have_attributes(universal: true, amount_percentage: 31, auto_apply: false)
        expect(code.products).to be_empty
      end

      it "leaves auto apply off when it is false or omitted" do
        post @action, params: @params.merge(universal: "true", auto_apply: "false")
        post @action, params: @params.merge(name: "omitted", universal: "true")

        expect(@user.offer_codes.alive.pluck(:code, :auto_apply)).to contain_exactly(["hi", false], ["omitted", false])
      end

      it "keeps a code product-specific when universal is a string other than true" do
        post @action, params: @params.merge(universal: "False")
        post @action, params: @params.merge(name: "no", universal: "no")

        codes = @user.offer_codes.alive
        expect(codes.pluck(:code, :universal)).to contain_exactly(["hi", false], ["no", false])
        expect(codes.map(&:products)).to all(contain_exactly(@product))
      end

      it "leaves auto apply off when it is a string other than true" do
        post @action, params: @params.merge(universal: "true", auto_apply: "False")

        expect(@user.offer_codes.alive.pluck(:code, :auto_apply)).to contain_exactly(["hi", false])
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

      it "marks offer codes created from the CLI" do
        request.user_agent = "gumroad-cli/1.0"

        post @action, params: @params.merge(offer_type: "cents")

        expect(@product.reload.offer_codes.alive.count).to eq 1
        expect(@product.offer_codes.alive.first.created_via_cli?).to be true
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

      it "creates a cents offer code with a minimum_amount_cents threshold" do
        post @action, params: @params.merge(offer_type: "cents", minimum_amount_cents: 5000)

        expect(@product.reload.offer_codes.alive.count).to eq 1
        offer_code = @product.offer_codes.alive.first
        expect(offer_code.amount_cents).to eq @new_offer_code_params[:amount_off]
        expect(offer_code.minimum_amount_cents).to eq 5000
      end

      it "creates a percent offer code with a minimum_amount_cents threshold" do
        post @action, params: @params.merge(offer_type: "percent", minimum_amount_cents: 5000)

        expect(@product.reload.offer_codes.alive.count).to eq 1
        offer_code = @product.offer_codes.alive.first
        expect(offer_code.amount_percentage).to eq @new_offer_code_params[:amount_off]
        expect(offer_code.minimum_amount_cents).to eq 5000
      end

      it "leaves minimum_amount_cents nil when not provided" do
        post @action, params: @params.merge(offer_type: "cents")

        expect(@product.reload.offer_codes.alive.first.minimum_amount_cents).to be(nil)
      end

      it "returns minimum_amount_cents in the response when set" do
        post @action, params: @params.merge(offer_type: "cents", minimum_amount_cents: 5000)

        result = response.parsed_body.deep_symbolize_keys
        expect(result[:offer_code][:minimum_amount_cents]).to eq(5000)
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

      it "returns a universal offer code that excludes the product" do
        universal_offer_code = create(:universal_offer_code, user: @user, code: "UNI", excluded_products: [@product])

        get @action, params: @params.merge(id: universal_offer_code.external_id)

        result = response.parsed_body.deep_symbolize_keys
        expect(result[:success]).to eq(true)
        expect(result[:offer_code][:id]).to eq(universal_offer_code.external_id)
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

      it "does not let a product-specific code auto apply" do
        put @action, params: @params.merge(auto_apply: "true")

        expect(response.parsed_body["success"]).to eq(false)
        expect(@offer_code.reload.auto_apply).to eq(false)
      end

      it "enables auto apply on a universal code from a JSON boolean" do
        @offer_code.update!(universal: true, products: [])

        put @action, params: @params.merge(auto_apply: true), as: :json

        expect(response.parsed_body["success"]).to eq(true)
        expect(@offer_code.reload.auto_apply).to eq(true)
      end

      it "enables auto apply on a universal code from the string true" do
        @offer_code.update!(universal: true, products: [])

        put @action, params: @params.merge(auto_apply: "true")

        expect(response.parsed_body["success"]).to eq(true)
        expect(@offer_code.reload.auto_apply).to eq(true)
      end

      it "leaves auto apply off when it is a string other than true" do
        @offer_code.update!(universal: true, products: [])

        put @action, params: @params.merge(auto_apply: "False")

        expect(response.parsed_body["success"]).to eq(true)
        expect(@offer_code.reload.auto_apply).to eq(false)
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

      it "updates offer code minimum_amount_cents" do
        put @action, params: @params.merge(minimum_amount_cents: 5000)

        expect(@product.reload.offer_codes.alive.count).to eq(1)
        expect(@product.offer_codes.alive.first.minimum_amount_cents).to eq(5000)
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
  describe "sale schedule" do
    %i[create update].each do |action|
      context "on #{action}" do
        let(:product) { create(:product, user: @user, price_cents: 10_000) }
        let(:token) { create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products") }
        let!(:existing_code) { create(:percentage_offer_code, user: @user, universal: true, products: []) if action == :update }
        let(:starts_at) { "2026-11-27T00:00:00-05:00" }
        let(:ends_at) { "2026-12-01T00:00:00-05:00" }

        define_method(:write_sale) do |attributes|
          parameters = { access_token: token.token, link_id: product.external_id }
          if action == :create
            post :create, params: parameters.merge(name: "SALE30", amount_off: 30, offer_type: "percent", universal: true).merge(attributes), as: :json
          else
            put :update, params: parameters.merge(id: existing_code.external_id).merge(attributes), as: :json
          end
        end

        it "saves the schedule and returns UTC timestamps" do
          write_sale(valid_at: starts_at, expires_at: ends_at, auto_apply: true, sale_label: "Black Friday")

          expect(response.parsed_body).to include("success" => true)
          code = @user.offer_codes.alive.sole
          expect(code).to have_attributes(valid_at: Time.utc(2026, 11, 27, 5), expires_at: Time.utc(2026, 12, 1, 5))
          expect(response.parsed_body["offer_code"]).to include("valid_at" => "2026-11-27T05:00:00Z", "expires_at" => "2026-12-01T05:00:00Z", "auto_apply" => true, "sale_label" => "Black Friday")
        end

        ["2026-11-27T00:00:60-05:00", "2027-02-30T00:00:00Z", "2027-04-31T00:00:00Z", "2026-11-27T24:00:00Z", "not-a-date", "2026-11-27", "2026-11-27T00:00:00", false, 1, ["2026-11-27T00:00:00Z"], { time: "2026-11-27T00:00:00Z" }].each do |invalid|
          it "rejects an invalid timestamp #{invalid.inspect} without saving any settings" do
            before_attributes = existing_code&.attributes
            expect { write_sale(valid_at: starts_at, expires_at: invalid, auto_apply: true) }.not_to change(OfferCode, :count)

            expect(response.parsed_body).to include("success" => false, "message" => "expires_at must be an RFC 3339 timestamp with a time zone, or null.")
            expect(existing_code.reload.attributes).to eq(before_attributes) if existing_code
          end
        end

        it "rejects an end before the start" do
          write_sale(valid_at: ends_at, expires_at: starts_at)

          expect(response.parsed_body).to include("success" => false, "message" => "The discount code's start date must be earlier than its end date.")
        end

        it "rejects an end without a start" do
          write_sale(expires_at: ends_at)

          expect(response.parsed_body).to include("success" => false)
        end

        it "keeps omitted dates unchanged" do
          existing_code&.update!(valid_at: Time.iso8601(starts_at), expires_at: Time.iso8601(ends_at))
          write_sale(auto_apply: true)

          expect(response.parsed_body).to include("success" => true)
          if existing_code
            expect(existing_code.reload).to have_attributes(valid_at: Time.utc(2026, 11, 27, 5), expires_at: Time.utc(2026, 12, 1, 5))
          else
            expect(@user.offer_codes.alive.sole).to have_attributes(valid_at: nil, expires_at: nil)
          end
        end

        it "accepts cleared dates" do
          existing_code&.update!(valid_at: Time.iso8601(starts_at), expires_at: Time.iso8601(ends_at))
          write_sale(valid_at: nil, expires_at: "")

          expect(response.parsed_body).to include("success" => true)
          expect(@user.offer_codes.alive.sole).to have_attributes(valid_at: nil, expires_at: nil)
        end
      end
    end
  end
  describe "store-level offer codes" do
    let(:product) { create(:product, user: @user, price_currency_type: "usd", price_cents: 2000) }
    let(:token) { create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_products") }
    let(:parameters) { { access_token: token.token } }
    let(:code) { create(:offer_code, user: @user, universal: true, products: [], amount_cents: 100, amount_percentage: nil, currency_type: "eur", auto_apply: true, excluded_products: [product]) }

    it "lists an automatic sale that a product-scoped list cannot see" do
      code
      get :index, params: parameters.merge(link_id: product.external_id)
      expect(response.parsed_body["offer_codes"]).to eq([])

      get :index, params: parameters

      expect(response.parsed_body["offer_codes"]).to include(a_hash_including("id" => code.external_id, "auto_apply" => true, "currency_type" => "eur"))
    end

    it "finds an expired automatic sale before older pages of manual codes" do
      code.update!(valid_at: 2.months.ago, expires_at: 1.month.ago, created_at: 3.months.ago)
      Array.new(30) { |index| create(:percentage_offer_code, user: @user, universal: true, products: [], code: "MANUAL#{index}") }

      get :index, params: parameters.merge(auto_apply: "true")

      expect(response.parsed_body["offer_codes"].map { _1["id"] }).to eq([code.external_id])
      expect(response.parsed_body).not_to have_key("next_page_key")

      get :index, params: parameters.merge(auto_apply: "false")
      expect(response.parsed_body["offer_codes"]).to all(include("auto_apply" => false))
      expect(response.parsed_body["offer_codes"].length).to eq(10)
    end

    it "rejects an invalid automatic-application filter" do
      get :index, params: parameters.merge(auto_apply: "yes")
      expect(response).to have_http_status(:bad_request)
    end

    it "reads and disables a sale without an eligible product" do
      get :show, params: parameters.merge(id: code.external_id)
      expect(response.parsed_body["offer_code"]).to include("id" => code.external_id)

      put :update, params: parameters.merge(id: code.external_id, auto_apply: false)

      expect(response.parsed_body["success"]).to eq(true)
      expect(code.reload.auto_apply).to be(false)
    end

    it "paginates codes with the same creation time without duplicates" do
      codes = travel_to(Time.utc(2026, 10, 15)) do
        Array.new(11) { |index| create(:percentage_offer_code, user: @user, universal: true, products: [], code: "PAGE#{index}") }
      end
      get :index, params: parameters
      first = response.parsed_body
      expect(first["offer_codes"].map { _1["id"] }).to eq(codes.last(10).reverse.map(&:external_id))
      expect(first["next_page_url"]).to start_with("/v2/offer_codes?")

      get :index, params: parameters.merge(page_key: first["next_page_key"])

      expect(response.parsed_body["offer_codes"].map { _1["id"] }).to eq([codes.first.external_id])
      expect(response.parsed_body).not_to have_key("next_page_key")
    end

    it "excludes deleted codes and another seller's codes" do
      code
      create(:percentage_offer_code, user: @user, universal: true, products: [], deleted_at: Time.current)
      create(:percentage_offer_code, universal: true, products: [])
      get :index, params: parameters
      expect(response.parsed_body["offer_codes"].map { _1["id"] }).to eq([code.external_id])
    end

    %i[show update].each do |action|
      it "refuses #{action} for another seller's code" do
        other_code = create(:percentage_offer_code, universal: true, products: [])
        if action == :show
          get :show, params: parameters.merge(id: other_code.external_id)
        else
          put :update, params: parameters.merge(id: other_code.external_id, auto_apply: true)
        end
        expect(response.parsed_body).to include("success" => false, "message" => "The offer_code was not found.")
        expect(other_code.reload.auto_apply).to be(false)
      end
    end

    it "requires a sales or product-edit scope for store-wide reads" do
      token.update!(scopes: "view_public")
      get :index, params: parameters
      expect(response).to have_http_status(:forbidden)
    end

    ["invalid", ["x"], { "cursor" => "x" }].each do |cursor|
      it "rejects an invalid pagination cursor #{cursor.inspect}" do
        get :index, params: parameters.merge(page_key: cursor)
        expect(response).to have_http_status(:bad_request)
      end
    end
  end
end
