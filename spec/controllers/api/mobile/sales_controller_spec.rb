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

      it "notifies Bugsnag and responds with error message" do
        expect(Bugsnag).to receive(:notify).with(instance_of(ActiveRecord::RecordInvalid))

        patch :refund, params: @params.merge(id: @purchase.external_id, amount: "100")

        expect(response.parsed_body).to eq "success" => false, "message" => "Sorry, something went wrong."
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end
end
