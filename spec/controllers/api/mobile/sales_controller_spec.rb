# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::SalesController, :vcr do
  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @purchaser = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api").token
    }
    @purchase = create(:purchase_in_progress, link: @product, seller: @seller, price_cents: 100, total_transaction_cents: 100,
                                              fee_cents: 30, chargeable: create(:chargeable))
    @purchase.process!
    @purchase.mark_successful!
  end

  describe "GET show" do
    it "returns purchase information" do
      get :show, params: @params.merge(id: @purchase.external_id)

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["purchase"].to_json).to eq(@purchase.json_data_for_mobile(include_sale_details: true).to_json)
    end

    it "returns customer details, charges, and emails" do
      get :show, params: @params.merge(id: @purchase.external_id)

      expect(response).to be_successful
      body = response.parsed_body
      seller_context = SellerContext.new(user: @seller, seller: @seller)
      expect(body["customer"].to_json).to eq(CustomerPresenter.new(purchase: @purchase).customer(pundit_user: seller_context).to_json)
      expect(body["charges"]).to eq([])
      expect(body["emails"].length).to eq(1)
      expect(body["emails"].first).to include("type" => "receipt", "id" => @purchase.external_id)
    end
  end

  describe "GET index" do
    before do
      travel_to(Time.utc(2024, 1, 1)) do
        @older_purchase = create(:purchase, link: @product, seller: @seller, email: "alice@example.com", full_name: "Alice Apple", price_cents: 300)
      end
      travel_to(Time.utc(2024, 2, 1)) do
        @newer_purchase = create(:purchase, link: @product, seller: @seller, email: "bob@example.com", full_name: "Bob Banana", price_cents: 200)
      end
      index_model_records(Purchase)
    end

    it "returns sales sorted by most recent" do
      get :index, params: @params

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["purchases"].map { _1["id"] }).to eq([@purchase.external_id, @newer_purchase.external_id, @older_purchase.external_id])
      expect(body["purchases"].second).to include(
        "email" => "bob@example.com",
        "product_name" => @product.name,
      )
      expect(body["pagination"]).to eq("count" => 3, "page" => 1, "pages" => 1, "next" => nil)
    end

    it "filters sales with the query parameter" do
      get :index, params: @params.merge(query: "alice@example.com")

      body = response.parsed_body
      expect(body["purchases"].map { _1["id"] }).to eq([@older_purchase.external_id])
      expect(body["pagination"]["count"]).to eq(1)
    end

    it "paginates sales" do
      stub_const("Api::Mobile::SalesController::SALES_PER_PAGE", 2)

      get :index, params: @params

      body = response.parsed_body
      expect(body["purchases"].map { _1["id"] }).to eq([@purchase.external_id, @newer_purchase.external_id])
      expect(body["pagination"]).to eq("count" => 3, "page" => 1, "pages" => 2, "next" => 2)

      get :index, params: @params.merge(page: 2)

      body = response.parsed_body
      expect(body["purchases"].map { _1["id"] }).to eq([@older_purchase.external_id])
      expect(body["pagination"]).to eq("count" => 3, "page" => 2, "pages" => 2, "next" => nil)
    end

    it "returns 504 when Elasticsearch times out" do
      allow(PurchaseSearchService).to receive(:search).and_raise(Faraday::TimeoutError)

      get :index, params: @params

      expect(response).to have_http_status(:gateway_timeout)
      expect(response.parsed_body).to eq("success" => false, "message" => "Sales request timed out")
    end
  end

  describe "PUT update" do
    it "updates the purchase email" do
      put :update, params: @params.merge(id: @purchase.external_id, email: "new@example.com")

      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.email).to eq("new@example.com")
    end
  end

  describe "POST change_can_contact" do
    it "updates can_contact" do
      post :change_can_contact, params: @params.merge(id: @purchase.external_id, can_contact: "false")

      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.can_contact).to eq(false)
    end
  end

  describe "PUT revoke_access and undo_revoke_access" do
    it "toggles access revocation" do
      put :revoke_access, params: @params.merge(id: @purchase.external_id)
      expect(@purchase.reload.is_access_revoked).to eq(true)

      put :undo_revoke_access, params: @params.merge(id: @purchase.external_id)
      expect(@purchase.reload.is_access_revoked).to eq(false)
    end
  end

  describe "PUT review_response" do
    before do
      create(:product_review, purchase: @purchase, link: @product, rating: 5)
    end

    it "creates and deletes a review response" do
      put :update_review_response, params: @params.merge(id: @purchase.external_id, message: "Thank you!")

      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.original_product_review.response.message).to eq("Thank you!")

      delete :destroy_review_response, params: @params.merge(id: @purchase.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.original_product_review.response).to be_nil
    end
  end

  describe "GET options" do
    it "returns the product's variant options" do
      get :options, params: @params.merge(id: @purchase.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["options"]).to eq(@product.options.as_json)
    end
  end

  describe "GET missed_posts" do
    it "returns missed posts for the purchase" do
      get :missed_posts, params: @params.merge(id: @purchase.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["missed_posts"]).to eq([])
    end
  end

  describe "PATCH refund" do
    context "when the purchase is not found" do
      it "responds with HTTP 404" do
        patch :refund, params: @params.merge(id: "notfound")

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
      end
    end

    context "when the purchase is not paid" do
      it "responds with HTTP 404" do
        purchase = create(:free_purchase)
        patch :refund, params: @params.merge(id: purchase.external_id)

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
      end
    end

    context "when the purchase is already refunded" do
      it "responds with HTTP 404" do
        @purchase.update!(stripe_refunded: true)
        patch :refund, params: @params.merge(id: @purchase.external_id)

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
      end
    end

    context "when the amount contains a comma" do
      it "responds with invalid request error" do
        patch :refund, params: @params.merge(id: @purchase.external_id, amount: "1,00")

        expect(response.parsed_body).to eq "success" => false, "message" => "Commas not supported in refund amount."
      end
    end

    context "when the purchase is refunded" do
      it "responds with HTTP success" do
        allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(10_00)
        @seller.update_attribute(:refund_fee_notice_shown, false)
        expect do
          patch :refund, params: @params.merge(id: @purchase.external_id)

          expect(response).to be_successful
          expect(response.parsed_body).to eq "success" => true, "id" => @purchase.external_id, "message" => "Purchase successfully refunded.", "partially_refunded" => false
        end.to change { @purchase.reload.refunded? }.from(false).to(true)
         .and change { @purchase.seller.refund_fee_notice_shown? }.from(false).to(true)
      end
    end

    context "when there's a refunding error" do
      before do
        allow_any_instance_of(Purchase).to receive(:refund!).and_return(false)
        allow_any_instance_of(Purchase).to receive_message_chain(:errors, :full_messages, :to_sentence).and_return("Refund error")
      end

      it "response with error message" do
        patch :refund, params: @params.merge(id: @purchase.external_id, amount: "100")

        expect(response.parsed_body).to eq "success" => false, "message" => "Refund error"
      end
    end

    context "when there's a record invalid exception" do
      before do
        allow_any_instance_of(Purchase).to receive(:refund!).and_raise(ActiveRecord::RecordInvalid)
      end

      it "notifies error tracker and responds with error message" do
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::RecordInvalid))

        patch :refund, params: @params.merge(id: @purchase.external_id, amount: "100")

        expect(response.parsed_body).to eq "success" => false, "message" => "Sorry, something went wrong."
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end
end
