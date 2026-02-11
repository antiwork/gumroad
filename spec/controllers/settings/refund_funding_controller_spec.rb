# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"

describe Settings::RefundFundingController, :vcr do
  let(:seller) { create(:user) }
  let(:credit_card) { create(:credit_card, user: seller) }

  before { sign_in seller }

  describe "GET #show" do
    it_behaves_like "authentication required for action", :get, :show

    context "when no funding card is configured" do
      it "returns enabled as false" do
        get :show, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["enabled"]).to be false
        expect(json["credit_card"]).to be_nil
      end
    end

    context "when funding card is configured" do
      before { seller.update!(refund_funding_credit_card: credit_card) }

      it "returns enabled as true with card details" do
        get :show, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["enabled"]).to be true
        expect(json["credit_card"]["visual"]).to be_present
      end
    end
  end

  describe "POST #create" do
    it_behaves_like "authentication required for action", :post, :create

    context "when chargeable cannot be built" do
      before do
        allow(CardParamsHelper).to receive(:get_card_data_handling_mode).and_return("stripejs.0")
        allow(CardParamsHelper).to receive(:check_for_errors).and_return(nil)
        allow(CardParamsHelper).to receive(:build_chargeable).and_return(nil)
      end

      it "returns an error" do
        post :create, params: { stripe_payment_method_id: "pm_test", card_data_handling_mode: "stripejs.0" }, format: :json

        expect(response).to have_http_status(:unprocessable_content)
        json = JSON.parse(response.body)
        expect(json["success"]).to be false
        expect(json["error"]).to eq("Invalid card information")
      end
    end

    context "when chargeable is valid" do
      let(:chargeable) { build(:chargeable) }

      before do
        allow(CardParamsHelper).to receive(:get_card_data_handling_mode).and_return("stripejs.0")
        allow(CardParamsHelper).to receive(:check_for_errors).and_return(nil)
        allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable)
      end

      it "creates the card and associates it with the seller" do
        expect {
          post :create, params: { stripe_payment_method_id: "pm_test", card_data_handling_mode: "stripejs.0" }, format: :json
        }.to change(CreditCard, :count).by(1)

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["success"]).to be true
        expect(json["enabled"]).to be true
        expect(json["credit_card"]).to be_present
        expect(seller.reload.refund_funding_credit_card).to be_present
      end
    end
  end

  describe "DELETE #destroy" do
    it_behaves_like "authentication required for action", :delete, :destroy

    context "when funding card exists" do
      before { seller.update!(refund_funding_credit_card: credit_card) }

      it "removes the funding card association and resets the banner flag" do
        seller.update!(dismissed_refund_payment_method_banner: true)

        delete :destroy, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["success"]).to be true
        expect(json["enabled"]).to be false
        expect(json["credit_card"]).to be_nil
        expect(seller.reload.refund_funding_credit_card).to be_nil
        expect(seller.reload.dismissed_refund_payment_method_banner?).to be false
      end
    end

    context "when no funding card exists" do
      it "still returns success" do
        delete :destroy, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["success"]).to be true
        expect(json["enabled"]).to be false
      end
    end
  end

  describe "POST #dismiss_banner" do
    it "dismisses the banner" do
      expect(seller.dismissed_refund_payment_method_banner?).to be false

      post :dismiss_banner, format: :json

      expect(response).to be_successful
      expect(seller.reload.dismissed_refund_payment_method_banner?).to be true
    end

    context "when banner is already dismissed" do
      before { seller.update!(dismissed_refund_payment_method_banner: true) }

      it "still returns success" do
        post :dismiss_banner, format: :json

        expect(response).to be_successful
        expect(seller.reload.dismissed_refund_payment_method_banner?).to be true
      end
    end
  end
end
