# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Checkout::UpsellsController do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:product1) { create(:product_with_digital_versions, user: seller, price_cents: 1000) }
  let(:product2) { create(:product_with_digital_versions, user: seller, price_cents: 500) }
  let!(:upsell1) { create(:upsell, product: product1, variant: product1.alive_variants.second, name: "Upsell 1", seller:, cross_sell: true, replace_selected_products: true) }
  let!(:upsell2) { create(:upsell, product: product2, offer_code: create(:offer_code, products: [product2], user: seller), name: "Upsell 2", seller:) }
  let!(:upsell2_variant) { create(:upsell_variant, upsell: upsell2, selected_variant: product2.alive_variants.first, offered_variant: product2.alive_variants.second) }

  include_context "with user signed in as admin for seller"

  UPSELL_KEYS = [
    "id",
    "name",
    "cross_sell",
    "replace_selected_products",
    "universal",
    "paused",
    "text",
    "description",
    "product",
    "discount",
    "selected_products",
    "upsell_variants"
  ]

  describe "GET index" do
    render_views

    it_behaves_like "authorize called for action", :get, :index do
      let(:policy_klass) { Checkout::UpsellPolicy }
      let(:record) { Upsell }
    end

    it "returns HTTP success and assigns correct instance variables" do
      expect(Checkout::UpsellsPresenter).to receive(:new).and_call_original
      get :index

      expect(response).to be_successful
      expect(response.body).to have_selector("title:contains('Upsells')", visible: false)
    end
  end

  describe "GET statistics" do
    before do
      build_list :product, 5 do |product, i|
        product.name = "Product #{i}"
        create_list(:upsell_purchase, 2, upsell: upsell1, selected_product: product)
        upsell1.selected_products << product
      end

      create_list(:upsell_purchase, 20, upsell: upsell2, selected_product: product2, upsell_variant: upsell2_variant)
      chargedback_purchase = create(:upsell_purchase, upsell: upsell2, selected_product: product2, upsell_variant: upsell2_variant).purchase
      chargedback_purchase.update!(chargeback_date: Time.current)
    end

    it_behaves_like "authorize called for action", :get, :statistics do
      let(:policy_klass) { Checkout::UpsellPolicy }
      let(:request_params) { { id: upsell1.external_id } }
      let(:record) { upsell1 }
    end

    it "returns the upsell's statistics" do
      get :statistics, params: { id: upsell1.external_id }, as: :json
      expect(response.parsed_body).to eq(
        {
          "uses" => {
            "total" => 10,
            "selected_products" => {
              upsell1.selected_products.first.external_id => 2,
              upsell1.selected_products.second.external_id => 2,
              upsell1.selected_products.third.external_id => 2,
              upsell1.selected_products.fourth.external_id => 2,
              upsell1.selected_products.fifth.external_id => 2,
            },
            "upsell_variants" => {},
          },
          "revenue_cents" => 10000
        }
      )

      get :statistics, params: { id: upsell2.external_id }, as: :json
      expect(response.parsed_body).to eq(
        {
          "uses" => {
            "total" => 20,
            "selected_products" => {
              product2.external_id => 20
            },
            "upsell_variants" => {
              upsell2_variant.external_id => 20
            }
          }, "revenue_cents" => 10000
        }
      )
    end
  end

  describe "GET cart_item" do
    context "product belongs to seller" do
      let(:product) { create(:product, user: seller) }

      it "returns the a cart item for the product" do
        get :cart_item, params: { product_id: product.external_id }, as: :json

        checkout_presenter = CheckoutPresenter.new(logged_in_user: nil, ip: nil)
        expect(response.parsed_body.deep_symbolize_keys).to eq(
          checkout_presenter.checkout_product(
            product,
            product.cart_item({}),
            {}
          )
        )
      end
    end

    context "product doesn't belong to seller" do
      it "returns a 404 error" do
        expect { get :cart_item, params: { product_id: create(:product).external_id } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:policy_klass) { Checkout::UpsellPolicy }
      let(:record) { Upsell }
    end

    it "returns HTTP success and creates an upsell" do
      expect do
        post :create, params: {
          name: "Course upsell",
          text: "Complete course upsell",
          description: "You'll enjoy a range of exclusive features, including...",
          cross_sell: false,
          replace_selected_products: false,
          paused: true,
          product_id: product1.external_id,
          upsell_variants: [{ selected_variant_id: product1.alive_variants.first.external_id, offered_variant_id: product1.alive_variants.second.external_id }],
        }, as: :json
      end.to change { seller.upsells.count }.by(1)

      upsell = seller.upsells.last

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["upsells"].map { _1["id"] }).to eq([upsell.external_id, upsell2.external_id, upsell1.external_id])
      expect(response.parsed_body["upsells"].first.keys).to match_array(UPSELL_KEYS)
      expect(response.parsed_body["pagination"]["page"]).to eq(1)

      expect(upsell.name).to eq("Course upsell")
      expect(upsell.text).to eq("Complete course upsell")
      expect(upsell.description).to eq("You'll enjoy a range of exclusive features, including...")
      expect(upsell.cross_sell).to eq(false)
      expect(upsell.replace_selected_products).to eq(false)
      expect(upsell.paused).to eq(true)
      expect(upsell.product).to eq(product1)
      expect(upsell.variant).to eq(nil)
      expect(upsell.upsell_variants.first.selected_variant).to eq(product1.alive_variants.first)
      expect(upsell.upsell_variants.first.offered_variant).to eq(product1.alive_variants.second)
      expect(upsell.upsell_variants.length).to eq(1)
    end

    context "when the upsell is a cross-sell" do
      it "returns HTTP success and creates an upsell" do
        expect do
          post :create, params: {
            name: "Course upsell",
            text: "Complete course upsell",
            description: "You'll enjoy a range of exclusive features, including...",
            cross_sell: true,
            replace_selected_products: true,
            paused: false,
            product_id: product1.external_id,
            variant_id: product1.alive_variants.first.external_id,
            product_ids: [product2.external_id],
            offer_code: { amount_cents: 200 },
          }, as: :json
        end.to change { seller.upsells.count }.by(1)

        upsell = seller.upsells.last

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["upsells"].map { _1["id"] }).to eq([upsell.external_id, upsell2.external_id, upsell1.external_id])
        expect(response.parsed_body["upsells"].first.keys).to match_array(UPSELL_KEYS)
        expect(response.parsed_body["pagination"]["page"]).to eq(1)

        expect(upsell.name).to eq("Course upsell")
        expect(upsell.text).to eq("Complete course upsell")
        expect(upsell.description).to eq("You'll enjoy a range of exclusive features, including...")
        expect(upsell.cross_sell).to eq(true)
        expect(upsell.replace_selected_products).to eq(true)
        expect(upsell.paused).to eq(false)
        expect(upsell.product).to eq(product1)
        expect(upsell.variant).to eq(product1.alive_variants.first)
        expect(upsell.selected_products).to eq([product2])
        expect(upsell.offer_code.amount_cents).to eq(200)
        expect(upsell.offer_code.amount_percentage).to be_nil
        expect(upsell.offer_code.products).to eq([product1])
        expect(upsell.upsell_variants.length).to eq(0)
      end
    end

    context "when there is a validation error" do
      let(:product) { create(:product_with_digital_versions) }

      it "returns the associated error message" do
        expect do
          post :create, params: {
            name: "Course upsell",
            text: "Complete course upsell",
            description: "You'll enjoy a range of exclusive features, including...",
            cross_sell: true,
            product_id: product1.external_id,
            variant_id: product.alive_variants.first.external_id,
            product_ids: [product2.external_id],
            offer_code: { amount_cents: 200 },
          }, as: :json
        end.to change { seller.upsells.count }.by(0)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error"]).to eq("The offered variant must belong to the offered product.")
      end
    end

    context "when offering a call as upsell" do
      let(:product) { create(:call_product, user: seller) }

      it "returns an error message" do
        expect do
          post :create, params: {
            name: "Call upsell",
            text: "Call me",
            description: "Let's chat!",
            cross_sell: false,
            product_id: product.external_id,
            offer_code: { amount_cents: 200 },
          }, as: :json
        end.to change { seller.upsells.count }.by(0)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error"]).to eq("Calls cannot be offered as upsells.")
      end
    end
  end

  describe "PUT update" do
    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { Checkout::UpsellPolicy }
      let(:record) { upsell1 }
      let(:request_params) { { id: upsell1.external_id } }
    end

    it "allows updating a cross-sell to an upsell" do
      expect do
        put :update, params: {
          id: upsell1.external_id,
          name: "Course upsell",
          text: "Complete course upsell",
          description: "You'll enjoy a range of exclusive features, including...",
          cross_sell: false,
          replace_selected_products: false,
          paused: true,
          product_id: product1.external_id,
          upsell_variants: [{ selected_variant_id: product1.alive_variants.first.external_id, offered_variant_id: product1.alive_variants.second.external_id }],
        }, as: :json
        upsell1.reload
      end.to change { upsell1.name }.from("Upsell 1").to("Course upsell")
        .and change { upsell1.text }.from("Take advantage of this excellent offer!").to("Complete course upsell")
        .and change { upsell1.description }.from("This offer will only last for a few weeks.").to("You'll enjoy a range of exclusive features, including...")
        .and change { upsell1.cross_sell }.from(true).to(false)
        .and change { upsell1.replace_selected_products }.from(true).to(false)
        .and change { upsell1.paused }.from(false).to(true)
        .and change { upsell1.upsell_variants.length }.from(0).to(1)
        .and change { upsell1.variant }.from(product1.alive_variants.second).to(nil)

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["upsells"].map { _1["id"] }).to eq([upsell1.external_id, upsell2.external_id])
      expect(response.parsed_body["upsells"].first.keys).to match_array(UPSELL_KEYS)
      expect(response.parsed_body["pagination"]["page"]).to eq(1)

      expect(upsell1.product).to eq(product1)
      expect(upsell1.upsell_variants.first.selected_variant).to eq(product1.alive_variants.first)
      expect(upsell1.upsell_variants.first.offered_variant).to eq(product1.alive_variants.second)
    end

    it "allows updating an upsell to a cross-sell" do
      expect do
        put :update, params: {
          id: upsell2.external_id,
          name: "Course upsell",
          text: "Complete course upsell",
          description: "You'll enjoy a range of exclusive features, including...",
          cross_sell: true,
          replace_selected_products: false,
          paused: false,
          product_id: product1.external_id,
          variant_id: product1.alive_variants.first.external_id,
          product_ids: [product2.external_id],
          offer_code: { amount_cents: 200 },
        }, as: :json
        upsell2.reload
      end.to change { upsell2.name }.from("Upsell 2").to("Course upsell")
        .and change { upsell2.text }.from("Take advantage of this excellent offer!").to("Complete course upsell")
        .and change { upsell2.description }.from("This offer will only last for a few weeks.").to("You'll enjoy a range of exclusive features, including...")
        .and change { upsell2.cross_sell }.from(false).to(true)
        .and change { upsell2.product }.from(product2).to(product1)
        .and change { upsell2.variant }.from(nil).to(product1.alive_variants.first)
        .and change { upsell2.selected_products }.from([]).to([product2])
        .and change { upsell2.offer_code.amount_cents }.from(100).to(200)
        .and change { upsell2.offer_code.products }.from([product2]).to([product1])
        .and change { upsell2.upsell_variants.first.alive? }.from(true).to(false)

      expect(upsell2.offer_code.amount_percentage).to be_nil
      expect(upsell2.replace_selected_products).to eq(false)
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["upsells"].map { _1["id"] }).to eq([upsell2.external_id, upsell1.external_id])
      expect(response.parsed_body["upsells"].first.keys).to match_array(UPSELL_KEYS)
      expect(response.parsed_body["pagination"]["page"]).to eq(1)
    end

    it "allows updating a cross-sell's offer code" do
      expect do
        put :update, params: {
          id: upsell1.external_id,
          product_id: upsell1.product.external_id,
          offer_code: { amount_cents: 200 },
        }, as: :json
        upsell1.reload
      end.to change { upsell1.offer_code&.amount_cents }.from(nil).to(200)

      expect do
        put :update, params: {
          id: upsell1.external_id,
          product_id: upsell1.product.external_id,
          offer_code: { amount_percentage: 10 },
        }, as: :json
        upsell1.reload
      end.to change { upsell1.offer_code.amount_cents }.from(200).to(nil)
        .and change { upsell1.offer_code.amount_percentage }.from(nil).to(10)
    end

    context "when there is a validation error" do
      let(:product) { create(:product_with_digital_versions) }

      it "returns the associated error message" do
        expect do
          put :update, params: {
            id: upsell1.external_id,
            name: "Course upsell",
            text: "Complete course upsell",
            description: "You'll enjoy a range of exclusive features, including...",
            cross_sell: true,
            product_id: product1.external_id,
            variant_id: product.alive_variants.first.external_id,
            product_ids: [product2.external_id],
            offer_code: { amount_cents: 200 },
          }, as: :json
        end.to change { seller.upsells.count }.by(0)

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["error"]).to eq("The offered variant must belong to the offered product.")
      end
    end

    context "when the offer code doesn't exist" do
      it "returns a 404 error" do
        expect { put :update, params: { id: "" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "DELETE destroy" do
    it "returns HTTP success and marks the offer code as deleted" do
      delete :destroy, params: { id: upsell2.external_id }, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)

      expect(upsell2.reload.deleted_at).to be_present
      expect(upsell2_variant.reload.deleted_at).to be_present
      expect(upsell2.reload.offer_code.deleted_at).to be_present
    end
  end
end
