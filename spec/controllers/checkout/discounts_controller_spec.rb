# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Checkout::DiscountsController do
  let(:seller) { create(:named_seller) }

  before do
    # Allow all GlobalConfig calls to pass through by default
    allow(GlobalConfig).to receive(:get).and_call_original
    # Override specific keys for obfuscate_ids
    allow(GlobalConfig).to receive(:get).with("OBFUSCATE_IDS_CIPHER_KEY").and_return("test_cipher_key_for_obfuscation")
    allow(GlobalConfig).to receive(:get).with("OBFUSCATE_IDS_NUMERIC_CIPHER_KEY").and_return("12345")
  end

  def transform_offer_code_props(offer_code_props)
    offer_code_props.transform_values do |v|
      v.is_a?(ActiveSupport::TimeWithZone) ? v.iso8601 : v
    end
  end

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:policy_klass) { Checkout::OfferCodePolicy }
      let(:record) { OfferCode }
    end

    it "returns HTTP success and assigns correct instance variables" do
      get :index
      expect(response).to be_successful
      expect(assigns[:title]).to eq("Discounts")

      expect(assigns[:presenter].pundit_user).to eq(controller.pundit_user)
    end

    context "when requesting CSV format" do
      let!(:collection) { create(:discount_collection, user: seller, name: "Test Collection") }
      let!(:offer_code_in_collection) { create(:offer_code, user: seller, discount_collection: collection, name: "Collection Code", code: "COL123") }
      let!(:offer_code_not_in_collection) { create(:offer_code, user: seller, discount_collection: nil, name: "Regular Code", code: "REG456") }

      it "exports all discounts when no collection filter is specified" do
        get :index, format: :csv
        expect(response).to be_successful
        expect(response.content_type).to include('text/csv')
        
        csv_lines = response.body.split("\n")
        expect(csv_lines.length).to be >= 2 # Header + at least 1 data row
        expect(csv_lines[0]).to include('Code,Name,Discount Type,Discount Value,Products,Max Uses,Valid From,Expires At,Collection,Created At')
        # By default, only non-collection discounts are shown
        expect(response.body).to include('REG456')
        expect(response.body).not_to include('COL123')
      end

      it "exports filtered discounts when collection_filter is specified" do
        get :index, params: { collection_filter: "in_collections" }, format: :csv
        expect(response).to be_successful
        expect(response.content_type).to include('text/csv')
        
        expect(response.body).to include('COL123')
        expect(response.body).not_to include('REG456')
      end

      it "exports specific collection discounts when collection_id is specified" do
        get :index, params: { collection_filter: "specific_collection", collection_id: collection.external_id }, format: :csv
        expect(response).to be_successful
        expect(response.content_type).to include('text/csv')
        
        expect(response.body).to include('COL123')
        expect(response.body).to include('Test Collection')
        expect(response.body).not_to include('REG456')
      end

      it "exports non-collection discounts when not_in_collections is specified" do
        get :index, params: { collection_filter: "not_in_collections" }, format: :csv
        expect(response).to be_successful
        expect(response.content_type).to include('text/csv')
        
        expect(response.body).to include('REG456')
        expect(response.body).not_to include('COL123')
      end

      it "combines collection filter with query parameter" do
        get :index, params: { collection_filter: "in_collections", query: "Collection Code" }, format: :csv
        expect(response).to be_successful
        expect(response.content_type).to include('text/csv')
        
        expect(response.body).to include('COL123')
        expect(response.body).not_to include('REG456')
      end
    end
  end

  describe "GET paged" do
    let!(:offer_codes) do
      build_list :offer_code, 3, user: seller do |offer_code, i|
        offer_code.update!(name: "Discount #{i}", code: "code#{i}", valid_at: i.days.ago, updated_at: i.days.ago)
      end
    end

    before do
      stub_const("Checkout::DiscountsController::PER_PAGE", 1)
    end

    it_behaves_like "authorize called for action", :get, :paged do
      let(:policy_klass) { Checkout::OfferCodePolicy }
      let(:record) { OfferCode }
    end

    it "returns HTTP success and assigns correct instance variables" do
      get :paged, params: { page: 1 }
      expect(response).to be_successful

      expect(assigns[:presenter].pundit_user).to eq(controller.pundit_user)
      expect(response.parsed_body["pagination"]["pages"]).to eq(3)
      expect(response.parsed_body["pagination"]["page"]).to eq(1)
      expect(response.parsed_body["offer_codes"].map(&:deep_symbolize_keys)).to eq(
        [
          transform_offer_code_props(
            Checkout::DiscountsPresenter.new(pundit_user: controller.pundit_user)
              .offer_code_props(offer_codes.first)
          )
        ]
      )
    end

    context "when `sort` is passed" do
      before do
        purchase = build(:free_purchase, link: create(:product, user: seller), offer_code: offer_codes.third)
        purchase.save!(validate: false)
      end

      it "returns the correct results" do
        get :paged, params: { page: 1, sort: { key: "revenue", direction: "desc" } }
        expect(response.parsed_body["offer_codes"].map(&:deep_symbolize_keys)).to eq(
          [
            transform_offer_code_props(
              Checkout::DiscountsPresenter.new(pundit_user: controller.pundit_user)
                .offer_code_props(offer_codes.third)
            )
          ]
        )
      end
    end

    context "when `query` is passed" do
      it "returns the correct results" do
        get :paged, params: { page: 1, query: "discount 2" }
        expect(response.parsed_body["offer_codes"].map(&:deep_symbolize_keys)).to eq(
          [
            transform_offer_code_props(
              Checkout::DiscountsPresenter.new(pundit_user: controller.pundit_user)
                .offer_code_props(offer_codes.third)
            )
          ]
        )

        get :paged, params: { page: 1, query: "code2" }
        expect(response.parsed_body["offer_codes"].map(&:deep_symbolize_keys)).to eq(
          [
            transform_offer_code_props(
              Checkout::DiscountsPresenter.new(pundit_user: controller.pundit_user)
                .offer_code_props(offer_codes.third)
            )
          ]
        )
      end
    end

    context "when `collection_filter` is passed" do
      let!(:collection) { create(:discount_collection, user: seller) }
      let!(:offer_codes_in_collection) do
        build_list :offer_code, 2, user: seller, discount_collection: collection do |offer_code, i|
          offer_code.update!(name: "Collection Discount #{i}", code: "col#{i}", updated_at: i.days.ago)
        end
      end
      let!(:offer_codes_not_in_collection) do
        build_list :offer_code, 2, user: seller, discount_collection: nil do |offer_code, i|
          offer_code.update!(name: "Regular Discount #{i}", code: "reg#{i}", updated_at: (i + 2).days.ago)
        end
      end

      before do
        stub_const("Checkout::DiscountsController::PER_PAGE", 10)
      end

      it "filters by 'not_in_collections' (default behavior)" do
        get :paged, params: { page: 1, collection_filter: "not_in_collections" }
        expect(response).to be_successful

        returned_codes = response.parsed_body["offer_codes"].map { |code| code["code"] }
        expect(returned_codes).to include("reg0", "reg1")
        expect(returned_codes).not_to include("col0", "col1")
      end

      it "filters by 'in_collections'" do
        get :paged, params: { page: 1, collection_filter: "in_collections" }
        expect(response).to be_successful

        returned_codes = response.parsed_body["offer_codes"].map { |code| code["code"] }
        expect(returned_codes).to include("col0", "col1")
        expect(returned_codes).not_to include("reg0", "reg1")
      end

      it "filters by 'all'" do
        get :paged, params: { page: 1, collection_filter: "all" }
        expect(response).to be_successful

        returned_codes = response.parsed_body["offer_codes"].map { |code| code["code"] }
        expect(returned_codes).to include("col0", "col1", "reg0", "reg1")
      end

      it "filters by 'specific_collection' with valid collection_id" do
        get :paged, params: { page: 1, collection_filter: "specific_collection", collection_id: collection.external_id }
        expect(response).to be_successful

        returned_codes = response.parsed_body["offer_codes"].map { |code| code["code"] }
        expect(returned_codes).to include("col0", "col1")
        expect(returned_codes).not_to include("reg0", "reg1")
      end

      it "filters by 'specific_collection' with invalid collection_id returns no results" do
        get :paged, params: { page: 1, collection_filter: "specific_collection", collection_id: "invalid_id" }
        expect(response).to be_successful

        expect(response.parsed_body["offer_codes"]).to be_empty
      end

      it "defaults to 'not_in_collections' when no collection_filter is specified" do
        get :paged, params: { page: 1 }
        expect(response).to be_successful

        returned_codes = response.parsed_body["offer_codes"].map { |code| code["code"] }
        expect(returned_codes).to include("reg0", "reg1")
        expect(returned_codes).not_to include("col0", "col1")
      end

      it "combines collection_filter with query parameter" do
        get :paged, params: { page: 1, collection_filter: "in_collections", query: "Collection Discount 0" }
        expect(response).to be_successful

        returned_codes = response.parsed_body["offer_codes"].map { |code| code["code"] }
        expect(returned_codes).to include("col0")
        expect(returned_codes).not_to include("col1", "reg0", "reg1")
      end

      it "combines collection_filter with sort parameter" do
        get :paged, params: { page: 1, collection_filter: "in_collections", sort: { key: "name", direction: "asc" } }
        expect(response).to be_successful

        returned_codes = response.parsed_body["offer_codes"].map { |code| code["code"] }
        expect(returned_codes).to eq(["col0", "col1"]) # Sorted by name ascending
      end
    end
  end

  describe "GET statistics" do
    let(:offer_code) { create(:offer_code, user: seller) }
    let(:products) { create_list(:product, 2, user: seller) }
    let!(:purchase1) do
      purchase = build(:free_purchase, 
        link: products.first, 
        offer_code: offer_code,
        price_cents: 100,
        total_transaction_cents: 100,
        displayed_price_cents: 100
      )
      purchase.save!(validate: false)
      purchase
    end
    let!(:purchase2) do
      purchase = build(:free_purchase, 
        link: products.second, 
        offer_code: offer_code,
        price_cents: 100,
        total_transaction_cents: 100,
        displayed_price_cents: 100
      )
      purchase.save!(validate: false)
      purchase
    end

    it_behaves_like "authorize called for action", :get, :statistics do
      let(:policy_klass) { Checkout::OfferCodePolicy }
      let(:request_params) { { id: offer_code.external_id } }
      let(:record) { offer_code }
    end

    it "returns the offer code's statistics" do
      get :statistics, params: { id: offer_code.external_id }, as: :json

      expect(response.parsed_body).to eq(
        {
          "uses" => {
            "total" => 2,
            "products" => {
              products.first.external_id => 1,
              products.second.external_id => 1,
            }
          },
          "revenue_cents" => 200
        }
      )
    end
  end

  describe "POST create" do
    let!(:existing_offer_code) { create(:offer_code, user: seller, products: [], updated_at: 1.day.ago) }

    it_behaves_like "authorize called for action", :post, :create do
      let(:policy_klass) { Checkout::OfferCodePolicy }
      let(:record) { OfferCode }
    end

    it "returns HTTP success and creates an offer code" do
      valid_at = ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year - 1}")
      expires_at = ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year + 1}")

      expect do
        post :create, params: {
          name: "Black Friday",
          code: "bfy2k",
          max_purchase_count: 2,
          amount_percentage: 10,
          currency_type: nil,
          universal: true,
          selected_product_ids: [],
          valid_at: valid_at.iso8601,
          expires_at: expires_at.iso8601,
          minimum_quantity: 2,
          duration_in_billing_cycles: 1,
          minimum_amount_cents: 1000,
        }, as: :json
      end.to change { seller.offer_codes.count }.by(1)

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)

      presenter = Checkout::DiscountsPresenter.new(pundit_user: controller.pundit_user)
      offer_code = seller.offer_codes.last
      expect(response.parsed_body["pagination"]["page"]).to eq(1)
      expect(response.parsed_body["offer_codes"].map(&:deep_symbolize_keys))
        .to eq([offer_code, existing_offer_code].map { transform_offer_code_props(presenter.offer_code_props(_1)) })

      expect(offer_code.name).to eq("Black Friday")
      expect(offer_code.code).to eq("bfy2k")
      expect(offer_code.max_purchase_count).to eq(2)
      expect(offer_code.amount_percentage).to eq(10)
      expect(offer_code.amount_cents).to eq(nil)
      expect(offer_code.currency_type).to eq(nil)
      expect(offer_code.universal).to eq(true)
      expect(offer_code.products).to eq([])
      expect(offer_code.valid_at).to eq(valid_at)
      expect(offer_code.expires_at).to eq(expires_at)
      expect(offer_code.minimum_quantity).to eq(2)
      expect(offer_code.duration_in_billing_cycles).to eq(1)
      expect(offer_code.minimum_amount_cents).to eq(1000)
    end

    context "when the offer code has several products" do
      before do
        @product1 = create(:product, user: seller)
        @product2 = create(:product, user: seller)
      end

      it "returns HTTP success and creates an offer code" do
        expect do
          post :create, params: {
            name: "Black Friday",
            code: "bfy2k",
            max_purchase_count: 2,
            amount_percentage: 1,
            currency_type: nil,
            universal: false,
            selected_product_ids: [@product1.external_id, @product2.external_id],
          }, as: :json
        end.to change { seller.offer_codes.count }.by(1)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(true)

        offer_code = seller.offer_codes.last
        expect(offer_code.name).to eq("Black Friday")
        expect(offer_code.code).to eq("bfy2k")
        expect(offer_code.max_purchase_count).to eq(2)
        expect(offer_code.amount_percentage).to eq(1)
        expect(offer_code.amount_cents).to eq(nil)
        expect(offer_code.currency_type).to eq(nil)
        expect(offer_code.universal).to eq(false)
        expect(offer_code.minimum_amount_cents).to eq(nil)
        expect(offer_code.products).to eq([@product1, @product2])
      end

      context "when the offer code has an invalid price" do
        it "returns HTTP success and an error message" do
          expect do
            post :create, params: {
              name: "Black Friday",
              code: "bfy2k",
              max_purchase_count: 2,
              amount_percentage: 10,
              currency_type: "usd",
              universal: false,
              selected_product_ids: [@product1.external_id, @product2.external_id],
            }, as: :json
          end.to change { seller.offer_codes.count  }.by(0)

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to eq("The price after discount for all of your products must be either $0 or at least $0.99.")
        end
      end
    end

    context "when the offer code's code is taken" do
      before do
        create(:offer_code, code: "code", user: seller)
      end

      it "returns HTTP success and an error message" do
        expect do
          post :create, params: {
            name: "Black Friday",
            code: "code",
            max_purchase_count: 2,
            amount_percentage: 1,
            currency_type: "usd",
            universal: true,
          }, as: :json
        end.to change { seller.offer_codes.count }.by(0)

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error_message"]).to eq("Discount code must be unique.")
      end
    end
  end

  describe "PUT update" do
    let!(:existing_offer_code) { create(:offer_code, user: seller, products: [], updated_at: 1.day.ago) }
    let(:offer_code) { create(:offer_code, name: "Discount 1", code: "code1", user: seller, max_purchase_count: 12, amount_percentage: 10, valid_at: ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year - 1}"), minimum_quantity: 1, duration_in_billing_cycles: 1) }

    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { Checkout::OfferCodePolicy }
      let(:record) { offer_code }
      let(:request_params) { { id: offer_code.external_id } }
    end

    it "returns HTTP success and updates the offer code" do
      put :update, params: {
        id: offer_code.external_id,
        name: "Discount 2",
        max_purchase_count: 2,
        amount_cents: 100,
        currency_type: "usd",
        universal: true,
        selected_product_ids: [],
        valid_at: nil,
        minimum_quantity: nil,
        duration_in_billing_cycles: nil,
        minimum_amount_cents: nil,
      }, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)

      presenter = Checkout::DiscountsPresenter.new(pundit_user: controller.pundit_user)
      offer_code.reload
      expect(response.parsed_body["pagination"]["page"]).to eq(1)
      expect(response.parsed_body["offer_codes"].map(&:deep_symbolize_keys)).to eq([offer_code, existing_offer_code].map { presenter.offer_code_props(_1) })

      expect(offer_code.name).to eq("Discount 2")
      expect(offer_code.code).to eq("code1")
      expect(offer_code.max_purchase_count).to eq(2)
      expect(offer_code.amount_percentage).to eq(nil)
      expect(offer_code.amount_cents).to eq(100)
      expect(offer_code.currency_type).to eq("usd")
      expect(offer_code.universal).to eq(true)
      expect(offer_code.products).to eq([])
      expect(offer_code.valid_at).to eq(nil)
      expect(offer_code.expires_at).to eq(nil)
      expect(offer_code.minimum_quantity).to eq(nil)
      expect(offer_code.duration_in_billing_cycles).to eq(nil)
      expect(offer_code.minimum_amount_cents).to eq(nil)
    end

    context "when the offer code has several products" do
      before do
        @product1 = create(:product, user: seller, price_cents: 1000)
        @product2 = create(:product, user: seller, price_cents: 500)
        @product3 = create(:product, user: seller, price_cents: 2000)
        @offer_code = create(:offer_code, name: "Discount 1", code: "code1", products: [@product1, @product2], user: seller, max_purchase_count: 12, minimum_amount_cents: 1000)
      end

      it "returns HTTP success and updates the offer code" do
        valid_at = ActiveSupport::TimeZone[seller.timezone].parse("January 1 #{Time.current.year - 1}")

        put :update, params: {
          id: @offer_code.external_id,
          name: "Discount 2",
          max_purchase_count: 10,
          amount_percentage: 1,
          universal: false,
          selected_product_ids: [@product1.external_id, @product3.external_id],
          valid_at: valid_at.iso8601,
          minimum_quantity: 5,
          minimum_amount_cents: 500,
        }, as: :json

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(true)

        offer_code = seller.offer_codes.last
        expect(offer_code.name).to eq("Discount 2")
        expect(offer_code.code).to eq("code1")
        expect(offer_code.max_purchase_count).to eq(10)
        expect(offer_code.amount_percentage).to eq(1)
        expect(offer_code.amount_cents).to eq(nil)
        expect(offer_code.currency_type).to eq(nil)
        expect(offer_code.universal).to eq(false)
        expect(offer_code.products).to eq([@product1, @product3])
        expect(offer_code.valid_at).to eq(valid_at)
        expect(offer_code.minimum_quantity).to eq(5)
        expect(offer_code.minimum_amount_cents).to eq(500)
      end

      context "when the offer code has an invalid price" do
        it "returns HTTP success and an error message" do
          put :update, params: {
            id: @offer_code.external_id,
            name: "Discount 2",
            max_purchase_count: 10,
            amount_cents: 450,
            universal: false,
            selected_product_ids: [@product1.external_id, @product2.external_id],
          }, as: :json

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to eq("The price after discount for all of your products must be either $0 or at least $0.99.")

          offer_code = seller.offer_codes.last
          expect(offer_code.name).to eq("Discount 1")
          expect(offer_code.code).to eq("code1")
          expect(offer_code.max_purchase_count).to eq(12)
          expect(offer_code.amount_percentage).to eq(nil)
          expect(offer_code.amount_cents).to eq(100)
          expect(offer_code.currency_type).to eq("usd")
          expect(offer_code.universal).to eq(false)
          expect(offer_code.products).to eq([@product1, @product2])
        end
      end
    end

    context "when the offer code doesn't exist" do
      it "returns a 404 error" do
        expect { put :update, params: { id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "DELETE destroy" do
    let (:offer_code) { create(:offer_code, user: seller) }

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:policy_klass) { Checkout::OfferCodePolicy }
      let(:record) { offer_code }
      let(:request_params) { { id: offer_code.external_id } }
    end

    it "returns HTTP success and marks the offer code as deleted" do
      delete :destroy, params: { id: offer_code.external_id }, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)

      expect(offer_code.reload.deleted_at).to_not be_nil
    end

    context "when the offer code is invalid" do
      before do
        offer_code.code = "$"
        offer_code.save(validate: false)
      end

      it "returns HTTP success and marks the offer code as deleted" do
        delete :destroy, params: { id: offer_code.external_id }, as: :json

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(true)

        expect(offer_code.reload.deleted_at).to_not be_nil
      end
    end

    context "when the offer code doesn't exist" do
      it "returns a 404 error" do
        expect { delete :destroy, params: { id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
