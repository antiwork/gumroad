# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"

describe Settings::RefundFundingController do
  let(:seller) { create(:user) }
  let(:credit_card) do
    CreditCard.new(
      stripe_customer_id: "cus_test_123",
      processor_payment_method_id: "pm_test_123",
      stripe_fingerprint: "fingerprint_123",
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      expiry_month: 12,
      expiry_year: 2030,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      holder_name: "Test User"
    ).tap(&:save!)
  end

  before { sign_in seller }

  describe "GET #show" do
    it_behaves_like "authentication required for action", :get, :show

    context "when no funding card is configured" do
      it "returns enabled as false and shows banner" do
        get :show, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["enabled"]).to be false
        expect(json["credit_card"]).to be_nil
        expect(json["show_banner"]).to be true
      end
    end

    context "when funding card is configured" do
      before { seller.update!(refund_funding_credit_card: credit_card) }

      it "returns enabled as true with card details" do
        get :show, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["enabled"]).to be true
        expect(json["name_on_card"]).to eq("Test User")
        expect(json["credit_card"]["visual"]).to eq("**** **** **** 4242")
        expect(json["show_banner"]).to be false
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
  end

  describe "DELETE #destroy" do
    it_behaves_like "authentication required for action", :delete, :destroy

    context "when funding card exists" do
      before { seller.update!(refund_funding_credit_card: credit_card) }

      it "removes the funding card association" do
        delete :destroy, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["success"]).to be true
        expect(seller.reload.refund_funding_credit_card).to be_nil
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
  end
end
