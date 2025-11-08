# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::Compliance::CardsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    sign_in @admin_user
  end

  describe "GET index" do
    let(:card_type) { "other" }
    let(:limit) { 10 }
    let(:transaction_date) { "02/22/2022" }

    before do
      stub_const("Admin::Compliance::CardsController::MAX_RESULT_LIMIT", limit)
      @purchase_visa = create(:purchase,
                              card_type: "visa",
                              card_visual: "**** **** **** 1234",
                              created_at: Time.zone.local(2019, 1, 17, 1, 2, 3),
                              price_cents: 777,
                              card_expiry_year: 2022,
                              card_expiry_month: 10)
    end

    it "passes purchases in Inertia props" do
      purchases_service = instance_double(Admin::Search::PurchasesService, perform: Purchase.none, valid?: true)
      allow(Admin::Search::PurchasesService).to receive(:new).with(card_type:, transaction_date: "2022-02-22", limit:).and_return(purchases_service)

      get :index, params: { card_type:, transaction_date: }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Compliance/Cards/Index")
      expect(inertia.props[:purchases]).to eq([])
      expect(inertia.props[:pagination]).to be_present
    end

    context "when transaction_date is invalid" do
      let(:transaction_date) { "02/22" }

      it "shows error flash message and no purchases" do
        purchases_service = instance_double(Admin::Search::PurchasesService, perform: Purchase.none, valid?: false)
        allow(Admin::Search::PurchasesService).to receive(:new).with(card_type:, transaction_date: "12/31", limit:).and_return(purchases_service)

        get :index, params: { card_type:, transaction_date: "12/31" }

        assert_response :success
        expect(flash[:alert]).to eq("Please enter the date using the MM/DD/YYYY format.")
        expect(inertia.component).to eq("Admin/Compliance/Cards/Index")
        expect(inertia.props[:purchases]).to eq([])
      end
    end

    it "when there is no results passes empty arrays in Inertia props" do
      purchases_service = instance_double(Admin::Search::PurchasesService, perform: Purchase.none, valid?: true)
      allow(Admin::Search::PurchasesService).to receive(:new).with(card_type:, limit:).and_return(purchases_service)

      get :index, params: { card_type: }

      assert_response :success
      expect(inertia.component).to eq("Admin/Compliance/Cards/Index")
      expect(inertia.props[:purchases]).to eq([])
      expect(inertia.props[:pagination]).to be_present
    end

    it "when a single purchase is found redirects to the admin purchase page when one purchase is found" do
      card_type = "visa"
      purchases_service = instance_double(Admin::Search::PurchasesService, perform: Purchase.where(id: @purchase_visa.id), valid?: true)
      allow(Admin::Search::PurchasesService).to receive(:new).with(card_type:, limit:).and_return(purchases_service)

      get :index, params: { card_type: }

      expect(response).to redirect_to admin_purchase_path(@purchase_visa)
    end

    it "when a multiple purchases are found, passes purchases in Inertia props" do
      card_type = "visa"
      purchase_2 = create(:purchase, card_type: "visa")
      purchases_service = instance_double(Admin::Search::PurchasesService, perform: Purchase.where(id: [@purchase_visa.id, purchase_2.id]), valid?: true)
      allow(Admin::Search::PurchasesService).to receive(:new).with(card_type:, limit:).and_return(purchases_service)

      get :index, params: { card_type: }

      assert_response :success
      expect(inertia.component).to eq("Admin/Compliance/Cards/Index")
      expect(inertia.props[:purchases]).to contain_exactly(hash_including(id: @purchase_visa.id), hash_including(id: purchase_2.id))
      expect(inertia.props[:pagination]).to be_present
    end

    context "when requesting JSON format" do
      it "returns JSON response" do
        purchases_service = instance_double(Admin::Search::PurchasesService, perform: Purchase.none, valid?: true)
        allow(Admin::Search::PurchasesService).to receive(:new).with(card_type:, limit:).and_return(purchases_service)

        get :index, params: { card_type: }, format: :json

        expect(response).to be_successful
        expect(response.content_type).to match(%r{application/json})
        expect(response.parsed_body["purchases"]).to eq([])
        expect(response.parsed_body["pagination"]).to be_present
      end
    end
  end
end
