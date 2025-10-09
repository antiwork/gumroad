# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Checkout::DiscountsController do
  render_views

  let(:seller) { create(:named_seller) }

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

    it "returns HTTP success and renders correct inertia props" do
      get :index
      expect(response).to be_successful
      expect(assigns[:title]).to eq("Discounts")

      expect(response.body).to include("data-page=")

      page_data_match = response.body.match(/data-page="([^"]*)"/)
      expect(page_data_match).to be_present, "Expected Inertia.js data-page attribute"

      page_data = JSON.parse(CGI.unescapeHTML(page_data_match[1]))
      expect(page_data["component"]).to eq("Checkout/Discounts/Index")

      props = page_data["props"]
      expect(props).to include("pagination", "offer_codes", "products")

      expect(props["products"]).to be_an(Array)
      expect(props["products"]).to all(have_key("id"))
      expect(props["products"]).to all(have_key("name"))
      expect(props["products"]).to all(have_key("archived"))
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

    it "returns HTTP success and renders correct JSON response" do
      get :paged, params: { page: 1 }
      expect(response).to be_successful

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
        create(:purchase, link: create(:product, user: seller), offer_code: offer_codes.third)
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
  end

  describe "GET statistics" do
    let(:offer_code) { create(:offer_code, user: seller) }
    let(:products) { create_list(:product, 2, user: seller) }
    let!(:purchase1) { create(:purchase, link: products.first, offer_code:) }
    let!(:purchase2) { create(:purchase, link: products.second, offer_code:) }

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
