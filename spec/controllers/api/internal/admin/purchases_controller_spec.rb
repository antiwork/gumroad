# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::PurchasesController do
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

  describe "POST refund" do
    let(:admin_user) { create(:admin_user) }
    let(:purchase) { create(:free_purchase, email: "buyer@example.com") }
    let(:params) { { id: purchase.external_id_numeric.to_s, email: purchase.email } }
    let(:refund_policy) { double("PurchaseRefundPolicy", fine_print: nil) }

    include_examples "admin api authorization required", :post, :refund, { id: "123", email: "buyer@example.com" }

    before do
      stub_const("GUMROAD_ADMIN_ID", admin_user.id)
    end

    it "returns 400 when email is missing" do
      post :refund, params: { id: purchase.external_id_numeric.to_s }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    context "when the purchase is not found or the email does not match" do
      it "returns 404 for a missing purchase" do
        post :refund, params: { id: "999999999", email: "buyer@example.com" }

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq({ success: false, message: "Purchase not found or email doesn't match" }.as_json)
      end

      it "returns 404 for a non-numeric purchase ID" do
        post :refund, params: { id: "abc", email: "buyer@example.com" }

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq({ success: false, message: "Purchase not found or email doesn't match" }.as_json)
      end

      it "returns 404 when the email does not match the purchase email" do
        post :refund, params: params.merge(email: "wrong@example.com")

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq({ success: false, message: "Purchase not found or email doesn't match" }.as_json)
      end

      it "matches email case-insensitively" do
        allow(Purchase).to receive(:find_by_external_id_numeric).with(purchase.external_id_numeric).and_return(purchase)
        allow(purchase).to receive(:within_refund_policy_timeframe?).and_return(true)
        allow(purchase).to receive(:purchase_refund_policy).and_return(refund_policy)
        purchase.errors.clear
        expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)

        post :refund, params: params.merge(email: purchase.email.upcase)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to be(true)
      end
    end

    context "when the purchase exists" do
      before do
        allow(Purchase).to receive(:find_by_external_id_numeric).with(purchase.external_id_numeric).and_return(purchase)
        allow(purchase).to receive(:within_refund_policy_timeframe?).and_return(true)
        allow(purchase).to receive(:purchase_refund_policy).and_return(refund_policy)
        purchase.errors.clear
      end

      it "fully refunds the purchase when amount_cents is omitted" do
        expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)

        post :refund, params: params

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["message"]).to eq("Successfully refunded purchase number #{purchase.external_id_numeric}")
        expect(response.parsed_body["purchase"]).to include("id" => purchase.external_id_numeric.to_s)
        expect(response.parsed_body["subscription_cancelled"]).to be(false)
      end

      it "performs a partial refund when amount_cents is provided" do
        expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: 5.0).and_return(true)

        post :refund, params: params.merge(amount_cents: "500")

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to be(true)
      end

      it "passes amount_cents equal to the full price through to refund! (model short-circuits to a full refund)" do
        expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: 10.0).and_return(true)

        post :refund, params: params.merge(amount_cents: "1000")

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to be(true)
      end

      it "returns 422 with the model error when amount_cents exceeds the refundable amount" do
        allow(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: 50.0) do
          purchase.errors.add :base, "Refund amount cannot be greater than the purchase price."
          false
        end

        post :refund, params: params.merge(amount_cents: "5000")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Refund amount cannot be greater than the purchase price.")
      end

      it "returns 422 when amount_cents is not a positive integer" do
        post :refund, params: params.merge(amount_cents: "0")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("amount_cents must be a positive integer")
      end

      it "returns 422 when the purchase is already fully refunded" do
        allow(purchase).to receive(:stripe_refunded).and_return(true)

        post :refund, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Purchase has already been fully refunded")
      end

      context "when the purchase is outside the refund policy timeframe" do
        before { allow(purchase).to receive(:within_refund_policy_timeframe?).and_return(false) }

        it "returns 422 without force" do
          post :refund, params: params

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to eq("Purchase is outside of the refund policy timeframe")
        end

        it "succeeds with force=true" do
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)

          post :refund, params: params.merge(force: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to be(true)
        end
      end

      context "when the refund policy has fine print" do
        before do
          allow(refund_policy).to receive(:fine_print).and_return("No refunds after 7 days")
        end

        it "returns 422 without force" do
          post :refund, params: params

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body["success"]).to be(false)
          expect(response.parsed_body["message"]).to eq("This product has specific refund conditions that require seller review")
        end

        it "succeeds with force=true" do
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)

          post :refund, params: params.merge(force: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to be(true)
        end
      end

      it "still surfaces an active chargeback error even when force=true" do
        allow(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil) do
          purchase.errors.add :base, Purchase::Refundable::ACTIVE_DISPUTE_REFUND_ERROR_MESSAGE
          false
        end

        post :refund, params: params.merge(force: "true")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq(Purchase::Refundable::ACTIVE_DISPUTE_REFUND_ERROR_MESSAGE)
      end

      context "with cancel_subscription=true" do
        let(:subscription) { instance_double(Subscription, deactivated?: false, price: nil) }

        it "cancels the subscription as an admin (not seller) after a successful refund" do
          allow(purchase).to receive(:subscription).and_return(subscription)
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)
          expect(subscription).to receive(:cancel!).with(by_seller: false, by_admin: true)

          post :refund, params: params.merge(cancel_subscription: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["subscription_cancelled"]).to be(true)
          expect(response.parsed_body).not_to have_key("subscription_cancel_error")
        end

        it "succeeds with subscription_cancelled: false when there is no subscription" do
          allow(purchase).to receive(:subscription).and_return(nil)
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)

          post :refund, params: params.merge(cancel_subscription: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["subscription_cancelled"]).to be(false)
          expect(response.parsed_body).not_to have_key("subscription_cancel_error")
        end

        it "does not re-cancel a subscription that is already deactivated" do
          deactivated_subscription = instance_double(Subscription, deactivated?: true, price: nil)
          allow(purchase).to receive(:subscription).and_return(deactivated_subscription)
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)
          expect(deactivated_subscription).not_to receive(:cancel!)

          post :refund, params: params.merge(cancel_subscription: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["subscription_cancelled"]).to be(false)
        end

        it "still returns success with subscription_cancel_error when cancel! raises after a successful refund" do
          allow(purchase).to receive(:subscription).and_return(subscription)
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)
          expect(subscription).to receive(:cancel!).with(by_seller: false, by_admin: true).and_raise(StandardError, "stripe blew up")

          post :refund, params: params.merge(cancel_subscription: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["subscription_cancelled"]).to be(false)
          expect(response.parsed_body["subscription_cancel_error"]).to eq("stripe blew up")
        end
      end
    end
  end
end
