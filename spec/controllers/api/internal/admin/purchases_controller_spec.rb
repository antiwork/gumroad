# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::PurchasesController do
  describe "POST search" do
    include_examples "admin api authorization required", :post, :search

    it "returns a bad request when no search parameters are provided" do
      post :search

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "At least one search parameter is required." }.as_json)
    end

    it "requires query when query-only modifiers are provided" do
      post :search, params: { purchase_status: "successful" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "query is required when product_title_query or purchase_status is provided." }.as_json)
    end

    it "returns a bad request when purchase_status is invalid" do
      post :search, params: { query: "buyer@example.com", purchase_status: "succesful" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "purchase_status must be one of: #{described_class::VALID_PURCHASE_STATUSES.to_sentence(last_word_connector: ', or ')}." }.as_json)
    end

    it "returns matching purchases as a capped list" do
      buyer_email = "buyer@example.com"
      older_purchase = create(:free_purchase, email: buyer_email, created_at: 2.days.ago)
      newer_purchase = create(:free_purchase, email: buyer_email, created_at: 1.day.ago)
      create(:free_purchase, email: "other@example.com")

      post :search, params: { query: buyer_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["count"]).to eq(2)
      expect(response.parsed_body["limit"]).to eq(described_class::MAX_SEARCH_RESULTS)
      expect(response.parsed_body["has_more"]).to be(false)

      purchases = response.parsed_body["purchases"]
      expect(purchases.map { _1["id"] }).to eq([newer_purchase.external_id_numeric.to_s, older_purchase.external_id_numeric.to_s])
      expect(purchases.first).to include(
        "email" => buyer_email,
        "id" => newer_purchase.external_id_numeric.to_s,
        "receipt_url" => receipt_purchase_url(newer_purchase.external_id, host: UrlService.domain_with_protocol, email: buyer_email)
      )
    end

    it "strips whitespace from query and product title search values" do
      buyer_email = "buyer@example.com"
      matching_product = create(:product, name: "Design course")
      matching_purchase = create(:free_purchase, link: matching_product, email: buyer_email)
      other_product = create(:product, name: "Writing course")
      create(:free_purchase, link: other_product, email: buyer_email)

      post :search, params: { query: " #{buyer_email} ", product_title_query: " Design " }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["purchases"].map { _1["id"] }).to eq([matching_purchase.external_id_numeric.to_s])
    end

    it "preloads purchase associations before serializing search results" do
      purchase = create(:free_purchase)
      search_service = instance_double(AdminSearchService)
      search_relation = Purchase.where(id: purchase.id)

      allow(AdminSearchService).to receive(:new).and_return(search_service)
      allow(search_service).to receive(:search_purchases).and_return(search_relation)
      expect(search_relation).to receive(:includes).with(:link, :seller, :refunds).and_call_original

      post :search, params: { query: purchase.email }

      expect(response).to have_http_status(:ok)
    end

    it "caps results and reports when more matches exist" do
      stub_const("#{described_class}::MAX_SEARCH_RESULTS", 2)
      buyer_email = "buyer@example.com"
      create(:free_purchase, email: buyer_email, created_at: 3.days.ago)
      second_purchase = create(:free_purchase, email: buyer_email, created_at: 2.days.ago)
      first_purchase = create(:free_purchase, email: buyer_email, created_at: 1.day.ago)

      post :search, params: { query: buyer_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["count"]).to eq(2)
      expect(response.parsed_body["limit"]).to eq(2)
      expect(response.parsed_body["has_more"]).to be(true)
      expect(response.parsed_body["purchases"].map { _1["id"] }).to eq([first_purchase.external_id_numeric.to_s, second_purchase.external_id_numeric.to_s])
    end

    it "uses the requested limit without exceeding the hard cap" do
      stub_const("#{described_class}::MAX_SEARCH_RESULTS", 2)
      buyer_email = "buyer@example.com"
      create(:free_purchase, email: buyer_email, created_at: 2.days.ago)
      returned_purchase = create(:free_purchase, email: buyer_email, created_at: 1.day.ago)

      post :search, params: { query: buyer_email, limit: 1 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["count"]).to eq(1)
      expect(response.parsed_body["limit"]).to eq(1)
      expect(response.parsed_body["has_more"]).to be(true)
      expect(response.parsed_body["purchases"].map { _1["id"] }).to eq([returned_purchase.external_id_numeric.to_s])
    end

    it "returns an empty list when no purchases match" do
      post :search, params: { query: "missing@example.com" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "purchases" => [],
        "count" => 0,
        "limit" => described_class::MAX_SEARCH_RESULTS,
        "has_more" => false
      )
    end

    it "returns a bad request when purchase_date is invalid" do
      post :search, params: { purchase_date: "2021-01", card_type: "visa" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "purchase_date must use YYYY-MM-DD format." }.as_json)
    end
  end

  describe "GET show" do
    include_examples "admin api authorization required", :get, :show, { id: "123" }

    it "returns purchase details for an exact purchase ID" do
      product = create(:product, name: "Example product")
      purchase = create(:free_purchase, link: product, email: "buyer@example.com")

      get :show, params: { id: purchase.external_id_numeric }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["purchase"]).to include(
        "id" => purchase.external_id_numeric.to_s,
        "email" => "buyer@example.com",
        "seller_email" => purchase.seller_email,
        "product_name" => "Example product",
        "link_name" => purchase.link_name,
        "product_id" => product.external_id_numeric.to_s,
        "formatted_total_price" => purchase.formatted_total_price,
        "price_cents" => 0,
        "purchase_state" => purchase.purchase_state,
        "refund_status" => nil,
        "receipt_url" => receipt_purchase_url(purchase.external_id, host: UrlService.domain_with_protocol, email: purchase.email)
      )
    end

    it "returns not found when the purchase ID does not exist" do
      get :show, params: { id: "999999999" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found" }.as_json)
    end

    it "does not coerce non-numeric purchase IDs" do
      purchase = create(:free_purchase)

      get :show, params: { id: "#{purchase.external_id_numeric}abc" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found" }.as_json)
    end
  end
end
