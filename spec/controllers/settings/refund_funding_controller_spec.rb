# frozen_string_literal: true

require "spec_helper"

describe Settings::RefundFundingController do
  let(:seller) { create(:user) }
  let(:credit_card) do
    CreditCard.new(
      stripe_customer_id: "cus_test123",
      processor_payment_method_id: "pm_test123",
      stripe_fingerprint: "fingerprint_123",
      visual: "Visa **** 4242",
      card_type: "visa",
      expiry_month: 12,
      expiry_year: 2030,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    ).tap(&:save!)
  end

  before do
    sign_in seller
  end

  describe "GET #show" do
    context "when no refund funding card is configured" do
      it "returns enabled as false" do
        get :show, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["enabled"]).to be false
        expect(json["credit_card"]).to be_nil
      end

      it "returns show_banner as true when banner not dismissed" do
        get :show, format: :json

        json = JSON.parse(response.body)
        expect(json["show_banner"]).to be true
      end

      it "returns show_banner as false when banner is dismissed" do
        seller.update!(dismissed_refund_payment_method_banner: true)

        get :show, format: :json

        json = JSON.parse(response.body)
        expect(json["show_banner"]).to be false
      end
    end

    context "when refund funding card is configured" do
      before do
        credit_card.update!(card_holder_name: "John Doe")
        seller.update!(refund_funding_credit_card: credit_card)
      end

      it "returns the card details" do
        get :show, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["enabled"]).to be true
        expect(json["credit_card"]["visual"]).to eq(credit_card.visual)
        expect(json["credit_card"]["card_type"]).to eq(credit_card.card_type)
      end

      it "returns the name on card" do
        get :show, format: :json

        json = JSON.parse(response.body)
        expect(json["name_on_card"]).to eq("John Doe")
      end

      it "returns show_banner as false" do
        get :show, format: :json

        json = JSON.parse(response.body)
        expect(json["show_banner"]).to be false
      end
    end
  end

  describe "DELETE #destroy" do
    context "when refund funding card is configured" do
      before do
        credit_card.update!(card_holder_name: "John Doe")
        seller.update!(refund_funding_credit_card: credit_card)
      end

      it "removes the refund funding card" do
        delete :destroy, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["success"]).to be true
        expect(json["enabled"]).to be false
        expect(seller.reload.refund_funding_credit_card).to be_nil
      end
    end
  end

  describe "POST #dismiss_banner" do
    context "when banner is not dismissed" do
      it "dismisses the banner" do
        post :dismiss_banner, format: :json

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["success"]).to be true
        expect(seller.reload.dismissed_refund_payment_method_banner).to be true
      end
    end

    context "when banner is already dismissed" do
      before do
        seller.update!(dismissed_refund_payment_method_banner: true)
      end

      it "keeps the banner dismissed" do
        post :dismiss_banner, format: :json

        expect(response).to be_successful
        expect(seller.reload.dismissed_refund_payment_method_banner).to be true
      end
    end
  end
end

describe "CustomersPresenter#show_refund_payment_method_banner" do
  let(:seller) { create(:user) }
  let(:credit_card) do
    CreditCard.new(
      stripe_customer_id: "cus_test123",
      processor_payment_method_id: "pm_test123",
      stripe_fingerprint: "fingerprint_123",
      visual: "Visa **** 4242",
      card_type: "visa",
      expiry_month: 12,
      expiry_year: 2030,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    ).tap(&:save!)
  end
  let(:pundit_user) { SellerContext.new(user: seller, seller: seller) }

  context "when no card configured and banner not dismissed" do
    it "returns true for show_refund_payment_method_banner" do
      presenter = CustomersPresenter.new(pundit_user: pundit_user)
      props = presenter.customers_props

      expect(props[:show_refund_payment_method_banner]).to be true
    end
  end

  context "when card is configured" do
    before do
      seller.update!(refund_funding_credit_card: credit_card)
    end

    it "returns false for show_refund_payment_method_banner" do
      presenter = CustomersPresenter.new(pundit_user: pundit_user)
      props = presenter.customers_props

      expect(props[:show_refund_payment_method_banner]).to be false
    end
  end

  context "when banner is dismissed" do
    before do
      seller.update!(dismissed_refund_payment_method_banner: true)
    end

    it "returns false for show_refund_payment_method_banner" do
      presenter = CustomersPresenter.new(pundit_user: pundit_user)
      props = presenter.customers_props

      expect(props[:show_refund_payment_method_banner]).to be false
    end
  end
end
