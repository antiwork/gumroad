# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::Compliance::CardsController, type: :controller, inertia: true do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    let(:card_type) { "other" }
    let(:transaction_date) { "02/22/2022" }

    before do
      @purchase_visa = create(:purchase,
                              card_type: "visa",
                              card_visual: "**** **** **** 1234",
                              created_at: Time.zone.local(2019, 1, 17, 1, 2, 3),
                              price_cents: 777,
                              card_expiry_year: 2022,
                              card_expiry_month: 10,
                              stripe_fingerprint: "test_fingerprint_visa")
    end

    context "with HTML format" do
      it "passes purchases in Inertia props" do
        get :index, params: { card_type:, transaction_date: }

        expect(response).to be_successful
        expect(assigns[:title]).to eq("Transaction results")
        expect(response.body).to include("data-page=")
        expect(inertia.component).to eq("Admin/Compliance/Cards/Index")
        expect(inertia.props[:purchases]).to eq([])
        expect(inertia.props[:pagination]).to be_present
      end

      context "when transaction_date is invalid" do
        it "shows error flash message and no purchases" do
          get :index, params: { card_type:, transaction_date: "12/31" }

          assert_response :success
          expect(flash[:alert]).to eq("Please enter the date using the MM/DD/YYYY format.")
          expect(inertia.props[:purchases]).to eq([])
        end
      end

      it "when there is no results passes empty arrays in Inertia props" do
        get :index, params: { card_type: }

        assert_response :success
        expect(inertia.props[:purchases]).to eq([])
        expect(inertia.props[:pagination]).to be_present
      end

      it "when a single purchase is found redirects to the admin purchase page when one purchase is found" do
        get :index, params: { card_type: "visa" }

        expect(response).to redirect_to admin_purchase_path(@purchase_visa)
      end

      it "when a multiple purchases are found, passes purchases in Inertia props" do
        purchase_2 = create(:purchase, card_type: "visa", stripe_fingerprint: "test_fingerprint")

        get :index, params: { card_type: "visa" }

        assert_response :success
        expect(inertia.props[:purchases]).to contain_exactly(hash_including(id: @purchase_visa.id), hash_including(id: purchase_2.id))
        expect(inertia.props[:pagination]).to be_present
      end

      context "with pagination" do
        let!(:purchase_1) { @purchase_visa }
        let!(:purchase_2) { create(:purchase, card_type: "visa", stripe_fingerprint: "test_fingerprint_visa", created_at: 4.seconds.ago) }
        let!(:purchase_3) { create(:purchase, card_type: "visa", stripe_fingerprint: "test_fingerprint_visa", created_at: 3.seconds.ago) }
        let!(:purchase_4) { create(:purchase, card_type: "visa", stripe_fingerprint: "test_fingerprint_visa", created_at: 2.seconds.ago) }
        let!(:purchase_5) { create(:purchase, card_type: "visa", stripe_fingerprint: "test_fingerprint_visa", created_at: 1.second.ago) }

        it "returns paginated results with per_page parameter" do
          get :index, params: { card_type: "visa", per_page: 2, page: 1 }
          expect(response).to be_successful
          expect(inertia.props[:purchases].length).to eq(2)
          expect(inertia.props[:purchases]).to contain_exactly(
            hash_including(id: purchase_5.id, email: purchase_5.email),
            hash_including(id: purchase_4.id, email: purchase_4.email)
          )
          expect(inertia.props[:pagination].page).to eq(1)

          get :index, params: { card_type: "visa", per_page: 2, page: 2 }
          expect(response).to be_successful
          expect(inertia.props[:purchases].length).to eq(2)
          expect(inertia.props[:purchases]).to contain_exactly(
            hash_including(id: purchase_3.id, email: purchase_3.email),
            hash_including(id: purchase_2.id, email: purchase_2.email)
          )
          expect(inertia.props[:pagination].page).to eq(2)

          get :index, params: { card_type: "visa", per_page: 2, page: 3 }
          expect(response).to be_successful
          expect(inertia.props[:purchases].length).to eq(1)
          expect(inertia.props[:purchases]).to contain_exactly(
            hash_including(id: purchase_1.id, email: purchase_1.email)
          )
        end
      end
    end

    context "with JSON format" do
      it "returns JSON response when requested" do
        get :index, params: { card_type: }, format: :json

        expect(response).to be_successful
        expect(response.content_type).to match(%r{application/json})
        expect(response.parsed_body["purchases"]).to eq([])
        expect(response.parsed_body["pagination"]).to be_present
      end
    end
  end
end
