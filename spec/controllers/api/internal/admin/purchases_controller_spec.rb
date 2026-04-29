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
      expect(purchases.map { _1.slice("email", "id", "receipt_url") }).to eq(
        [
          {
            "email" => buyer_email,
            "id" => newer_purchase.external_id_numeric.to_s,
            "receipt_url" => receipt_purchase_url(newer_purchase.external_id, host: UrlService.domain_with_protocol, email: buyer_email)
          },
          {
            "email" => buyer_email,
            "id" => older_purchase.external_id_numeric.to_s,
            "receipt_url" => receipt_purchase_url(older_purchase.external_id, host: UrlService.domain_with_protocol, email: buyer_email)
          }
        ]
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

    it "strips whitespace from exact-match search values" do
      seller = create(:user, email: "seller@example.com")
      product = create(:product, user: seller)
      buyer_email = "buyer@example.com"
      purchase = create(:free_purchase, link: product, email: buyer_email)
      license = create(:license, purchase:)
      purchase.update_columns(card_type: "visa", card_visual: "**** **** **** 4242", stripe_fingerprint: "test-fingerprint")

      [
        { email: " #{buyer_email} " },
        { creator_email: " #{seller.email} " },
        { license_key: " #{license.serial} " },
        { card_last4: " 4242 " },
        { card_type: " visa " },
      ].each do |search_params|
        post :search, params: search_params

        aggregate_failures(search_params.inspect) do
          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["purchases"].map { _1["id"] }).to eq([purchase.external_id_numeric.to_s])
        end
      end
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

    it "uses preloaded refunds when serializing refund details" do
      purchase = create(:free_purchase, stripe_refunded: true, stripe_partially_refunded: false, email: "refunded@example.com")
      refund = create(:refund, purchase:, amount_cents: 0)

      expect_any_instance_of(Purchase).not_to receive(:amount_refunded_cents)

      post :search, params: { query: purchase.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["purchases"].first).to include(
        "id" => purchase.external_id_numeric.to_s,
        "refund_status" => "refunded",
        "refund_date" => refund.created_at.as_json
      )
    end

    it "computes amount_refundable_cents_in_currency from preloaded refunds without an extra SUM query" do
      purchase = create(:free_purchase, email: "paid-buyer@example.com")
      purchase.update_columns(price_cents: 1000, charge_processor_id: "stripe", stripe_transaction_id: "ch_test")
      create(:refund, purchase:, amount_cents: 250)

      expect_any_instance_of(Purchase).not_to receive(:amount_refunded_cents)

      post :search, params: { query: purchase.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["purchases"].first).to include(
        "id" => purchase.external_id_numeric.to_s,
        "amount_refundable_cents_in_currency" => 750
      )
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
        "currency_type" => purchase.displayed_price_currency_type.to_s,
        "amount_refundable_cents_in_currency" => purchase.amount_refundable_cents_in_currency,
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
        allow(purchase).to receive(:stripe_transaction_id).and_return("ch_test")
        allow(purchase).to receive(:amount_refundable_cents).and_return(1000)
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
        allow(purchase).to receive(:stripe_transaction_id).and_return("ch_test")
        allow(purchase).to receive(:amount_refundable_cents).and_return(1000)
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

      it "returns 422 when amount_cents is a decimal-like string" do
        post :refund, params: params.merge(amount_cents: "5.99")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("amount_cents must be a positive integer")
      end

      it "returns 422 when amount_cents has trailing non-digit characters" do
        post :refund, params: params.merge(amount_cents: "12abc")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("amount_cents must be a positive integer")
      end

      it "returns 422 when amount_cents is negative" do
        post :refund, params: params.merge(amount_cents: "-100")

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("amount_cents must be a positive integer")
      end

      it "returns 422 when the purchase has no charge to refund" do
        allow(purchase).to receive(:stripe_transaction_id).and_return(nil)

        post :refund, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Purchase has no charge to refund")
      end

      it "returns 422 when the purchase has no remaining refundable amount" do
        allow(purchase).to receive(:amount_refundable_cents).and_return(0)

        post :refund, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Purchase has no charge to refund")
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
        let(:subscription) { instance_double(Subscription, deactivated?: false, cancelled_at: nil, price: nil) }

        it "cancels the subscription with admin/seller semantics after a successful refund" do
          allow(purchase).to receive(:subscription).and_return(subscription)
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)
          expect(subscription).to receive(:cancel!).with(by_seller: true, by_admin: true) do
            allow(subscription).to receive(:cancelled_at).and_return(Time.current)
          end

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
          deactivated_subscription = instance_double(Subscription, deactivated?: true, cancelled_at: 1.hour.ago, price: nil)
          allow(purchase).to receive(:subscription).and_return(deactivated_subscription)
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)
          expect(deactivated_subscription).not_to receive(:cancel!)

          post :refund, params: params.merge(cancel_subscription: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["subscription_cancelled"]).to be(false)
        end

        it "does not re-cancel a subscription that is already pending cancellation" do
          pending_subscription = instance_double(Subscription, deactivated?: false, cancelled_at: 1.day.from_now, price: nil)
          allow(purchase).to receive(:subscription).and_return(pending_subscription)
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)
          expect(pending_subscription).not_to receive(:cancel!)

          post :refund, params: params.merge(cancel_subscription: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["subscription_cancelled"]).to be(false)
        end

        it "still returns success with subscription_cancel_error when cancel! raises after a successful refund" do
          allow(purchase).to receive(:subscription).and_return(subscription)
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)
          expect(subscription).to receive(:cancel!).with(by_seller: true, by_admin: true).and_raise(StandardError, "stripe blew up")

          post :refund, params: params.merge(cancel_subscription: "true")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["subscription_cancelled"]).to be(false)
          expect(response.parsed_body["subscription_cancel_error"]).to eq("stripe blew up")
        end
      end

      context "with whitespace in the email parameter" do
        it "strips whitespace before comparing against the purchase email" do
          expect(purchase).to receive(:refund!).with(refunding_user_id: admin_user.id, amount: nil).and_return(true)

          post :refund, params: params.merge(email: "  #{purchase.email.upcase}  ")

          expect(response).to have_http_status(:ok)
          expect(response.parsed_body["success"]).to be(true)
        end
      end
    end
  end
end
