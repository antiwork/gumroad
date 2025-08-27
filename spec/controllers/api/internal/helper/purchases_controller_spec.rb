# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Helper::PurchasesController, :vcr do
  include HelperAISpecHelper

  let(:buyer) { create(:user) }
  let(:admin_user) { create(:admin_user) }

  before do
    request.headers["Authorization"] = "Bearer #{GlobalConfig.get("HELPER_TOOLS_TOKEN")}"
  end

  it "inherits from Api::Internal::Helper::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
  end

  describe "POST reassign_purchases" do
    let(:from_email) { "old@example.com" }
    let(:to_email) { "new@example.com" }
    let!(:target_user) { create(:user, email: to_email) }
    let!(:purchase1) { create(:purchase, email: from_email, purchaser: buyer) }
    let!(:purchase2) { create(:purchase, email: from_email, purchaser: buyer) }
    let!(:purchase3) { create(:purchase, email: from_email, purchaser: nil) }

    context "when both emails are provided" do
      it "reassigns purchases and updates purchaser_id when target user exists" do
        subscription = create(:subscription, user: buyer)
        subscription_purchase = create(:purchase, email: from_email, purchaser: buyer, is_original_subscription_purchase: true, subscription: subscription)

        post :reassign_purchases, params: { from: from_email, to: to_email }

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["count"]).to eq(4) # Updated count to include subscription_purchase

        purchase1.reload
        expect(purchase1.email).to eq(to_email)
        expect(purchase1.purchaser_id).to eq(target_user.id)

        purchase2.reload
        expect(purchase2.email).to eq(to_email)
        expect(purchase2.purchaser_id).to eq(target_user.id)

        purchase3.reload
        expect(purchase3.email).to eq(to_email)
        expect(purchase3.purchaser_id).to be_nil

        subscription_purchase.reload
        expect(subscription_purchase.email).to eq(to_email)
        expect(subscription_purchase.purchaser_id).to eq(target_user.id)

        subscription.reload
        expect(subscription.user).to eq(target_user)
      end

      it "reassigns purchases and sets purchaser_id to nil when target user doesn't exist" do
        subscription = create(:subscription, user: buyer)
        subscription_purchase = create(:purchase, email: from_email, purchaser: buyer, is_original_subscription_purchase: true, subscription: subscription)

        expect do
          post :reassign_purchases, params: { from: from_email, to: "nonexistent@example.com" }
        end.to change {
          Purchase.where(email: "nonexistent@example.com").count
        }.from(0).to(4) # Updated count to include subscription_purchase

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["count"]).to eq(4) # Updated count to include subscription_purchase

        purchase1.reload
        expect(purchase1.email).to eq("nonexistent@example.com")
        expect(purchase1.purchaser_id).to be_nil

        purchase2.reload
        expect(purchase2.email).to eq("nonexistent@example.com")
        expect(purchase2.purchaser_id).to be_nil

        purchase3.reload
        expect(purchase3.email).to eq("nonexistent@example.com")
        expect(purchase3.purchaser_id).to be_nil

        subscription_purchase.reload
        expect(subscription_purchase.email).to eq("nonexistent@example.com")
        expect(subscription_purchase.purchaser_id).to be_nil

        subscription.reload
        expect(subscription.user).to be_nil
      end
    end

    context "when parameters are missing" do
      it "returns an error when 'from' email is missing" do
        post :reassign_purchases, params: { to: to_email }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to include("Both 'from' and 'to' email addresses are required")
      end

      it "returns an error when 'to' email is missing" do
        post :reassign_purchases, params: { from: from_email }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to include("Both 'from' and 'to' email addresses are required")
      end
    end

    context "when no purchases are found" do
      it "returns a not found error" do
        post :reassign_purchases, params: { from: "no-purchases@example.com", to: to_email }

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("No purchases found for email: no-purchases@example.com")
      end
    end
  end

  describe "POST refund_last_purchase" do
    before do
      @purchase = create(:purchase_in_progress, email: buyer.email, purchaser: buyer, chargeable: create(:chargeable))
      @purchase.process!

      create(:purchase, created_at: 10.days.ago)
      @params = { email: @purchase.email }

      stub_const("GUMROAD_ADMIN_ID", admin_user.id)
    end

    context "when the last purchase can be refunded" do
      it "refunds the purchase" do
        expect do
          post :refund_last_purchase, params: @params
        end.to change { @purchase.reload.refunded? }.from(false).to(true)

        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to eq({ success: true, message: "Successfully refunded purchase number #{@purchase.external_id_numeric}" }.as_json)
      end
    end

    context "when the purchase cannot be refunded" do
      before do
        @error_message = "There is a temporary problem. Try to refund later."
        errors_double = double(full_messages: double(to_sentence: @error_message))
        allow_any_instance_of(Purchase).to receive(:refund_and_save!).and_return(false)
        allow_any_instance_of(Purchase).to receive(:errors).and_return(errors_double)
      end

      it "returns error response" do
        post :refund_last_purchase, params: @params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ success: false, message: @error_message }.as_json)
      end
    end
  end

  describe "POST resend_last_receipt" do
    before do
      @purchase = create(:purchase_in_progress, email: buyer.email, purchaser: buyer, chargeable: create(:chargeable))
      @purchase.process!

      create(:purchase, created_at: 10.days.ago)
      @params = { email: @purchase.email }
    end

    it "resends the last purchase's receipt" do
      post :resend_last_receipt, params: @params

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq({ success: true, message: "Successfully resent receipt for purchase number #{@purchase.external_id_numeric}" }.as_json)
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@purchase.id).on("critical")
    end
  end

  describe "POST resend_receipt_by_number" do
    before do
      @purchase = create(:purchase_in_progress, email: buyer.email, purchaser: buyer, chargeable: create(:chargeable))
      @purchase.process!
    end

    it "resends the receipt when purchase is found" do
      post :resend_receipt_by_number, params: { purchase_number: @purchase.external_id_numeric }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq({ success: true, message: "Successfully resent receipt for purchase number #{@purchase.external_id_numeric} to #{@purchase.email}" }.as_json)
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@purchase.id).on("critical")
    end

    it "returns 404 when purchase is not found" do
      post :resend_receipt_by_number, params: { purchase_number: "nonexistent" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, error: "Not found" }.as_json)
      expect(SendPurchaseReceiptJob.jobs.size).to eq(0)
    end
  end

  describe "POST search" do
    before do
      @purchase = create(:purchase_in_progress, email: buyer.email, purchaser: buyer, chargeable: create(:chargeable))
      @purchase.process!
      @params = { email: @purchase.email }
    end

    it "returns error if no parameters are provided" do
      post :search, params: {}

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body[:success]).to eq(false)
      expect(response.parsed_body[:message]).to eq("At least one of the parameters is required.")
    end

    it "returns purchase data if found" do
      purchase_json = @purchase.slice(:email, :link_name, :price_cents, :purchase_state, :created_at)
      purchase_json[:id] = @purchase.external_id_numeric
      purchase_json[:seller_email] = @purchase.seller_email
      purchase_json[:receipt_url] = receipt_purchase_url(@purchase.external_id, host: UrlService.domain_with_protocol, email: @purchase.email)
      purchase_json[:refund_status] = nil

      post :search, params: @params

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq({ success: true, message: "Purchase found", purchase: purchase_json }.as_json)
    end

    it "does not return purchase data if no purchase is found" do
      params = @params.merge(email: "user@example.com")
      post :search, params: params

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found" }.as_json)
    end

    context "when searching by paypal email" do
      it "returns purchase data if found" do
        purchase = create(:purchase, card_type: CardType::PAYPAL, card_visual: "user@example.com")
        purchase_json = purchase.slice(:email, :link_name, :price_cents, :purchase_state, :created_at)
        purchase_json[:id] = purchase.external_id_numeric
        purchase_json[:seller_email] = purchase.seller_email
        purchase_json[:receipt_url] = receipt_purchase_url(purchase.external_id, host: UrlService.domain_with_protocol, email: purchase.email)
        purchase_json[:refund_status] = nil
        params = @params.merge(email: "user@example.com")
        post :search, params: params

        expect(response.parsed_body).to eq({ success: true, message: "Purchase found", purchase: purchase_json }.as_json)
      end
    end

    context "when searching by card's last 4" do
      it "returns purchase data if found" do
        purchase = create(:purchase, card_visual: "**** **** **** 4242")
        purchase_json = purchase.slice(:email, :link_name, :price_cents, :purchase_state, :created_at)
        purchase_json[:id] = purchase.external_id_numeric
        purchase_json[:seller_email] = purchase.seller_email
        purchase_json[:receipt_url] = receipt_purchase_url(purchase.external_id, host: UrlService.domain_with_protocol, email: purchase.email)
        purchase_json[:refund_status] = nil
        params = { card_last4: "4242", timestamp: Time.now.to_i }
        post :search, params: params

        expect(response.parsed_body).to eq({ success: true, message: "Purchase found", purchase: purchase_json }.as_json)
      end
    end

    context "when purchase_date is invalid" do
      it "returns error message" do
        params = { purchase_date: "2021-01", card_type: "other", timestamp: Time.now.to_i }
        post :search, params: params
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({ success: false, message: "purchase_date must use YYYY-MM-DD format." }.as_json)
      end
    end

    context "when searching by charge amount" do
      it "returns purchase data if found" do
        purchase = create(:purchase, price_cents: 1000)
        purchase_json = purchase.slice(:email, :link_name, :price_cents, :purchase_state, :created_at)
        purchase_json[:id] = purchase.external_id_numeric
        purchase_json[:seller_email] = purchase.seller_email
        purchase_json[:receipt_url] = receipt_purchase_url(purchase.external_id, host: UrlService.domain_with_protocol, email: purchase.email)
        purchase_json[:refund_status] = nil
        params = { charge_amount: "10.00", timestamp: Time.now.to_i }
        post :search, params: params

        expect(response.parsed_body).to eq({ success: true, message: "Purchase found", purchase: purchase_json }.as_json)
      end
    end

    context "with refunded purchases" do
      it "returns fully refunded purchase data" do
        refunded_purchase = create(:purchase, stripe_refunded: true, stripe_partially_refunded: false, email: "refunded@example.com")
        refund = create(:refund, purchase: refunded_purchase, amount_cents: refunded_purchase.price_cents)

        purchase_json = refunded_purchase.slice(:email, :link_name, :price_cents, :purchase_state, :created_at)
        purchase_json[:id] = refunded_purchase.external_id_numeric
        purchase_json[:seller_email] = refunded_purchase.seller_email
        purchase_json[:receipt_url] = receipt_purchase_url(refunded_purchase.external_id, host: UrlService.domain_with_protocol, email: refunded_purchase.email)
        purchase_json[:refund_status] = "refunded"
        purchase_json[:refund_amount] = refunded_purchase.amount_refunded_cents
        purchase_json[:refund_date] = refund.created_at

        params = { email: "refunded@example.com", timestamp: Time.now.to_i }
        post :search, params: params

        expect(response.parsed_body).to eq({ success: true, message: "Purchase found", purchase: purchase_json }.as_json)
      end

      it "returns partially refunded purchase data" do
        partially_refunded_purchase = create(:purchase, stripe_refunded: false, stripe_partially_refunded: true, price_cents: 1000, email: "partial@example.com")
        refund = create(:refund, purchase: partially_refunded_purchase, amount_cents: 500)

        purchase_json = partially_refunded_purchase.slice(:email, :link_name, :price_cents, :purchase_state, :created_at)
        purchase_json[:id] = partially_refunded_purchase.external_id_numeric
        purchase_json[:seller_email] = partially_refunded_purchase.seller_email
        purchase_json[:receipt_url] = receipt_purchase_url(partially_refunded_purchase.external_id, host: UrlService.domain_with_protocol, email: partially_refunded_purchase.email)
        purchase_json[:refund_status] = "partially_refunded"
        purchase_json[:refund_amount] = partially_refunded_purchase.amount_refunded_cents
        purchase_json[:refund_date] = refund.created_at

        params = { email: "partial@example.com", timestamp: Time.now.to_i }
        post :search, params: params

        expect(response.parsed_body).to eq({ success: true, message: "Purchase found", purchase: purchase_json }.as_json)
      end
    end
  end

  describe "POST auto_refund_purchase" do
    let(:purchase) { instance_double(Purchase, id: 1, email: "test@example.com", external_id_numeric: 1) }
    let(:params) { { purchase_id: "12345", email: "test@example.com" } }
    let(:purchase_refund_policy) { double("PurchaseRefundPolicy", fine_print: nil) }

    before do
      stub_const("GUMROAD_ADMIN_ID", admin_user.id)

      allow(Purchase).to receive(:find_by_external_id_numeric).with(12345).and_return(purchase)
      allow(purchase).to receive(:within_refund_policy_timeframe?).and_return(true)
      allow(purchase).to receive(:purchase_refund_policy).and_return(purchase_refund_policy)
      allow(purchase).to receive(:refund_and_save!).with(admin_user.id).and_return(true)
    end

    context "when the purchase exists and email matches" do
      it "processes the refund when within policy timeframe and no fine print" do
        post :auto_refund_purchase, params: params

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)["success"]).to eq(true)
        expect(JSON.parse(response.body)["message"]).to eq("Successfully refunded purchase number 1")
      end

      it "returns an error when outside refund policy timeframe" do
        allow(purchase).to receive(:within_refund_policy_timeframe?).and_return(false)

        post :auto_refund_purchase, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Purchase is outside of the refund policy timeframe")
      end

      it "returns an error when fine print exists" do
        allow(purchase).to receive(:within_refund_policy_timeframe?).and_return(true)
        allow(purchase_refund_policy).to receive(:fine_print).and_return("Some fine print")

        post :auto_refund_purchase, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("This product has specific refund conditions that require seller review")
      end

      it "returns an error if the refund fails" do
        allow(purchase).to receive(:within_refund_policy_timeframe?).and_return(true)
        allow(purchase_refund_policy).to receive(:fine_print).and_return(nil)

        allow(purchase).to receive(:refund_and_save!).with(admin_user.id).and_return(false)

        post :auto_refund_purchase, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Refund failed for purchase number 1")
      end
    end

    context "when the purchase does not exist or email doesn't match" do
      it "returns a not found error when purchase doesn't exist" do
        allow(Purchase).to receive(:find_by_external_id_numeric).with(999999).and_return(nil)

        post :auto_refund_purchase, params: { purchase_id: "999999", email: "test@example.com" }

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Purchase not found or email doesn't match")
      end

      it "returns a not found error when email doesn't match" do
        mismatched_purchase = instance_double(Purchase, email: "different@example.com")
        allow(Purchase).to receive(:find_by_external_id_numeric).with(54321).and_return(mismatched_purchase)

        post :auto_refund_purchase, params: { purchase_id: "54321", email: "wrong@example.com" }

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Purchase not found or email doesn't match")
      end
    end
  end

  describe "POST refund_taxes_only" do
    let(:purchase) { instance_double(Purchase, id: 1, email: "test@example.com", external_id_numeric: 1) }
    let(:purchase) { instance_double(Purchase, id: 1, email: "test@example.com", external_id_numeric: 1) }
    let(:params) { { purchase_id: "12345", email: "test@example.com" } }

    before do
      stub_const("GUMROAD_ADMIN_ID", admin_user.id)
      allow(Purchase).to receive(:find_by_external_id_numeric).with(12345).and_return(purchase)
    end

    context "when the purchase exists and email matches" do
      it "successfully refunds taxes when refundable taxes are available" do
        allow(purchase).to receive(:refund_gumroad_taxes!).with(
          refunding_user_id: admin_user.id,
          note: nil,
          business_vat_id: nil
        ).and_return(true)

        post :refund_taxes_only, params: params

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)["success"]).to eq(true)
        expect(JSON.parse(response.body)["message"]).to eq("Successfully refunded taxes for purchase number 1")
      end

      it "includes note and business_vat_id when provided" do
        params_with_extras = params.merge(note: "Tax exemption", business_vat_id: "VAT123456")

        allow(purchase).to receive(:refund_gumroad_taxes!).with(
          refunding_user_id: admin_user.id,
          note: "Tax exemption",
          business_vat_id: "VAT123456"
        ).and_return(true)

        post :refund_taxes_only, params: params_with_extras

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)["success"]).to eq(true)
        expect(JSON.parse(response.body)["message"]).to eq("Successfully refunded taxes for purchase number 1")
      end

      it "returns an error when no refundable taxes are available" do
        allow(purchase).to receive(:refund_gumroad_taxes!).with(
          refunding_user_id: admin_user.id,
          note: nil,
          business_vat_id: nil
        ).and_return(false)

        allow(purchase).to receive(:errors).and_return(double(full_messages: double(presence: nil)))

        post :refund_taxes_only, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("No refundable taxes available")
      end

      it "returns specific error message when purchase has validation errors" do
        error_messages = ["Tax already refunded", "Invalid tax amount"]
        allow(purchase).to receive(:refund_gumroad_taxes!).and_return(false)
        allow(purchase).to receive(:errors).and_return(
          double(full_messages: double(presence: error_messages, to_sentence: "Tax already refunded and Invalid tax amount"))
        )

        post :refund_taxes_only, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Tax already refunded and Invalid tax amount")
      end
    end

    context "when the purchase does not exist or email doesn't match" do
      it "returns a not found error when purchase doesn't exist" do
        allow(Purchase).to receive(:find_by_external_id_numeric).with(999999).and_return(nil)

        post :refund_taxes_only, params: { purchase_id: "999999", email: "test@example.com" }

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Purchase not found or email doesn't match")
      end

      it "returns a not found error when email doesn't match (case insensitive)" do
        mismatched_purchase = instance_double(Purchase, email: "different@example.com")
        allow(Purchase).to receive(:find_by_external_id_numeric).with(54321).and_return(mismatched_purchase)

        post :refund_taxes_only, params: { purchase_id: "54321", email: "wrong@example.com" }

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Purchase not found or email doesn't match")
      end

      it "handles email matching case insensitively" do
        allow(purchase).to receive(:email).and_return("Test@Example.com")
        allow(purchase).to receive(:refund_gumroad_taxes!).and_return(true)

        post :refund_taxes_only, params: { purchase_id: "12345", email: "test@example.com" }

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body)["success"]).to eq(true)
      end
    end

    context "when required parameters are missing" do
      it "handles missing purchase_id gracefully" do
        post :refund_taxes_only, params: { email: "test@example.com" }

        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Both 'purchase_id' and 'email' parameters are required")
      end

      it "handles missing email gracefully" do
        post :refund_taxes_only, params: { purchase_id: "12345" }

        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)["success"]).to eq(false)
        expect(JSON.parse(response.body)["message"]).to eq("Both 'purchase_id' and 'email' parameters are required")
      end
    end
  end
end
