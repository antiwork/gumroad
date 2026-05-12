# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::PurchasesController do
  describe "GET lookup" do
    include_examples "admin api authorization required", :get, :lookup

    def lookup_purchase_ids
      response.parsed_body["purchases"].map { _1["id"] }
    end

    def create_lookup_purchase(seller, attributes = {})
      product = create(:product, user: seller)
      purchase = create(:free_purchase, seller:, link: product)
      purchase.update_columns(attributes) if attributes.present?
      purchase
    end

    def serialized_seller(seller)
      {
        "id" => seller.external_id,
        "email" => seller.email,
        "name" => seller.name,
      }
    end

    it "returns a bad request when no lookup key is provided" do
      get :lookup

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "stripe_fingerprint, browser_guid, or ip_address is required" }.as_json)
    end

    it "returns a bad request when the lookup key is blank" do
      get :lookup, params: { stripe_fingerprint: "" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "stripe_fingerprint, browser_guid, or ip_address is required" }.as_json)
    end

    it "returns a bad request when more than one lookup key is provided" do
      get :lookup, params: { stripe_fingerprint: "fp_shared", ip_address: "203.0.113.7" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "only one of stripe_fingerprint, browser_guid, ip_address is allowed" }.as_json)
    end

    it "returns an empty purchase list when the lookup key matches nothing" do
      get :lookup, params: { stripe_fingerprint: "missing" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "lookup" => { "field" => "stripe_fingerprint", "value" => "missing" },
        "purchases" => [],
        "pagination" => { "next" => nil, "limit" => 20 }
      )
    end

    it "returns purchases sharing a stripe fingerprint ordered by created_at and id descending" do
      first_seller = create(:user, email: "first-seller@example.com", name: "First Seller")
      second_seller = create(:user, email: "second-seller@example.com", name: "Second Seller")
      shared_time = 1.hour.ago.change(usec: 0)
      older = create_lookup_purchase(first_seller, stripe_fingerprint: "fp_shared", created_at: 2.hours.ago)
      same_time_older_id = create_lookup_purchase(first_seller, stripe_fingerprint: "fp_shared", created_at: shared_time)
      same_time_newer_id = create_lookup_purchase(second_seller, stripe_fingerprint: "fp_shared", created_at: shared_time)
      create_lookup_purchase(first_seller, stripe_fingerprint: "fp_shared_suffix", created_at: 30.minutes.ago)
      create_lookup_purchase(second_seller, stripe_fingerprint: nil, created_at: 15.minutes.ago)

      get :lookup, params: { stripe_fingerprint: " fp_shared " }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["lookup"]).to eq({ "field" => "stripe_fingerprint", "value" => "fp_shared" })
      expect(lookup_purchase_ids).to eq([same_time_newer_id, same_time_older_id, older].map { _1.external_id_numeric.to_s })

      first_row = response.parsed_body["purchases"].first
      expect(first_row).to include(
        "seller_email" => second_seller.email,
        "seller" => serialized_seller(second_seller)
      )
      expect(response.parsed_body["purchases"].map { _1["seller_email"] }).to contain_exactly(first_seller.email, first_seller.email, second_seller.email)
    end

    it "returns purchases sharing a browser GUID" do
      seller = create(:user)
      matching = create_lookup_purchase(seller, browser_guid: "browser-shared")
      create_lookup_purchase(seller, browser_guid: "browser-other")

      get :lookup, params: { browser_guid: "browser-shared" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["lookup"]).to eq({ "field" => "browser_guid", "value" => "browser-shared" })
      expect(lookup_purchase_ids).to eq([matching.external_id_numeric.to_s])
    end

    it "returns purchases sharing an IP address" do
      seller = create(:user)
      matching = create_lookup_purchase(seller, ip_address: "203.0.113.7")
      create_lookup_purchase(seller, ip_address: "198.51.100.4")

      get :lookup, params: { ip_address: "203.0.113.7" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["lookup"]).to eq({ "field" => "ip_address", "value" => "203.0.113.7" })
      expect(lookup_purchase_ids).to eq([matching.external_id_numeric.to_s])
    end

    it "paginates lookup results with a cursor" do
      seller = create(:user)
      newest = create_lookup_purchase(seller, stripe_fingerprint: "fp_paginated", created_at: 1.hour.ago)
      middle = create_lookup_purchase(seller, stripe_fingerprint: "fp_paginated", created_at: 2.hours.ago)
      oldest = create_lookup_purchase(seller, stripe_fingerprint: "fp_paginated", created_at: 3.hours.ago)

      get :lookup, params: { stripe_fingerprint: "fp_paginated", limit: 2 }

      expect(response).to have_http_status(:ok)
      expect(lookup_purchase_ids).to eq([newest, middle].map { _1.external_id_numeric.to_s })
      cursor = response.parsed_body["pagination"]["next"]
      expect(cursor).to be_present
      expect(response.parsed_body["pagination"]["limit"]).to eq(2)

      get :lookup, params: { stripe_fingerprint: "fp_paginated", limit: 2, cursor: }

      expect(response).to have_http_status(:ok)
      expect(lookup_purchase_ids).to eq([oldest.external_id_numeric.to_s])
      expect(response.parsed_body["pagination"]).to eq({ "next" => nil, "limit" => 2 })
    end

    it "returns a bad request when the cursor is invalid" do
      get :lookup, params: { stripe_fingerprint: "fp_shared", cursor: "invalid" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "invalid cursor" }.as_json)
    end

    it "preloads sellers instead of issuing one query per purchase row" do
      sellers = 3.times.map { create(:user) }
      sellers.each do |seller|
        create_lookup_purchase(seller, stripe_fingerprint: "fp_sellers")
      end

      seller_ids = sellers.map(&:id)
      seller_lookup_queries = []
      counter = lambda do |*, payload|
        sql = payload[:sql].to_s
        next if sql.start_with?("INSERT", "UPDATE", "DELETE", "BEGIN", "COMMIT", "SAVEPOINT", "RELEASE")
        next unless sql.start_with?("SELECT") && sql.include?("`users`")
        next unless sql.match?(/`users`\.`id` = \d+ LIMIT 1\z/)

        seller_lookup_queries << sql if seller_ids.any? { |id| sql.include?("`id` = #{id} ") }
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get :lookup, params: { stripe_fingerprint: "fp_sellers" }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["purchases"].length).to eq(3)
      expect(seller_lookup_queries).to be_empty,
                                       "expected zero per-row SELECTs for sellers, but got:\n#{seller_lookup_queries.join("\n")}"
    end
  end

  describe "GET search" do
    include_examples "admin api authorization required", :get, :search

    it "returns a bad request when no search parameters are provided" do
      get :search

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "At least one search parameter is required." }.as_json)
    end

    it "requires query when query-only modifiers are provided" do
      get :search, params: { purchase_status: "successful" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "query is required when product_title_query or purchase_status is provided." }.as_json)
    end

    it "returns a bad request when purchase_status is invalid" do
      get :search, params: { query: "buyer@example.com", purchase_status: "succesful" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "purchase_status must be one of: #{described_class::VALID_PURCHASE_STATUSES.to_sentence(last_word_connector: ', or ')}." }.as_json)
    end

    it "returns matching purchases as a capped list" do
      buyer_email = "buyer@example.com"
      older_purchase = create(:free_purchase, email: buyer_email, created_at: 2.days.ago)
      newer_purchase = create(:free_purchase, email: buyer_email, created_at: 1.day.ago)
      create(:free_purchase, email: "other@example.com")

      get :search, params: { query: buyer_email }

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

      get :search, params: { query: " #{buyer_email} ", product_title_query: " Design " }

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
        get :search, params: search_params

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
      expect(search_relation).to receive(:includes).with(*Api::Internal::Admin::BaseController::ADMIN_PURCHASE_INCLUDES).and_call_original

      get :search, params: { query: purchase.email }

      expect(response).to have_http_status(:ok)
    end

    it "preloads the affiliate_credit's affiliate_user so serialization does not fire one users SELECT per row" do
      buyer_email = "affiliate-cluster@example.com"
      affiliate_user_ids = 3.times.map do
        affiliate_user = create(:user)
        affiliate = create(:direct_affiliate, affiliate_user:)
        purchase = create(:free_purchase, email: buyer_email, affiliate:)
        create(:affiliate_credit, purchase:, affiliate:, affiliate_user:, amount_cents: 100, fee_cents: 10, basis_points: 500)
        affiliate_user.id
      end

      single_row_user_lookups = []
      counter = lambda do |*, payload|
        sql = payload[:sql].to_s
        next if sql.start_with?("INSERT", "UPDATE", "DELETE", "BEGIN", "COMMIT", "SAVEPOINT", "RELEASE")
        next unless sql.start_with?("SELECT") && sql.include?("`users`")
        next unless sql.match?(/`users`\.`id` = \d+ LIMIT 1\z/)

        single_row_user_lookups << sql
      end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        get :search, params: { query: buyer_email }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["purchases"].length).to eq(3)
      response.parsed_body["purchases"].each do |row|
        expect(row["affiliate_credit"]["affiliate_user_id"]).to be_present
      end

      lookups_for_affiliate_users = single_row_user_lookups.select do |sql|
        affiliate_user_ids.any? { |id| sql.include?("`id` = #{id} ") }
      end
      expect(lookups_for_affiliate_users).to be_empty,
                                             "expected zero per-row SELECTs for affiliate_user (preload should batch via IN), but got:\n#{lookups_for_affiliate_users.join("\n")}"
    end

    it "uses preloaded refunds when serializing refund details" do
      purchase = create(:free_purchase, stripe_refunded: true, stripe_partially_refunded: false, email: "refunded@example.com")
      refund = create(:refund, purchase:, amount_cents: 0)

      expect_any_instance_of(Purchase).not_to receive(:amount_refunded_cents)

      get :search, params: { query: purchase.email }

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

      get :search, params: { query: purchase.email }

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

      get :search, params: { query: buyer_email }

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

      get :search, params: { query: buyer_email, limit: 1 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["count"]).to eq(1)
      expect(response.parsed_body["limit"]).to eq(1)
      expect(response.parsed_body["has_more"]).to be(true)
      expect(response.parsed_body["purchases"].map { _1["id"] }).to eq([returned_purchase.external_id_numeric.to_s])
    end

    it "returns an empty list when no purchases match" do
      get :search, params: { query: "missing@example.com" }

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
      get :search, params: { purchase_date: "2021-01", card_type: "visa" }

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
        "seller" => {
          "id" => product.user.external_id,
          "email" => product.user.email,
          "name" => product.user.name,
        },
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

    it "returns nil seller fields when the purchase has no seller" do
      purchase = create(:free_purchase)
      purchase.update_columns(seller_id: nil)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["purchase"]).to include(
        "seller_email" => nil,
        "seller" => nil
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

    it "exposes the chargeback date when the purchase has been charged back" do
      purchase = create(:free_purchase, chargeback_date: 2.days.ago)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["chargeback_date"]).to eq(purchase.chargeback_date.as_json)
    end

    it "returns the raw IP, IP country, billing country, and card country" do
      purchase = create(:free_purchase)
      purchase.update_columns(
        ip_address: "203.0.113.42",
        ip_country: "United States",
        country: "Germany",
        card_country: "FR"
      )

      get :show, params: { id: purchase.external_id_numeric }

      payload = response.parsed_body["purchase"]
      expect(payload).to include(
        "ip_address" => "203.0.113.42",
        "ip_country" => "United States",
        "billing_country" => "Germany",
        "card_country" => "FR"
      )
    end

    it "computes country mismatch booleans across the production storage schemes (names for billing/ip, alpha-2 for card)" do
      purchase = create(:free_purchase)
      purchase.update_columns(country: "Germany", ip_country: "United States", card_country: "GB")

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["country_mismatches"]).to eq(
        "billing_vs_ip" => true,
        "billing_vs_card" => true,
        "ip_vs_card" => true
      )
    end

    it "treats a billing/IP country name and a matching card alpha-2 as equal" do
      purchase = create(:free_purchase)
      purchase.update_columns(country: "United States", ip_country: "United States", card_country: "US")

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["country_mismatches"]).to eq(
        "billing_vs_ip" => false,
        "billing_vs_card" => false,
        "ip_vs_card" => false
      )
    end

    it "treats blank country values as non-mismatches" do
      purchase = create(:free_purchase)
      purchase.update_columns(country: nil, ip_country: "United States", card_country: nil)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["country_mismatches"]).to eq(
        "billing_vs_ip" => false,
        "billing_vs_card" => false,
        "ip_vs_card" => false
      )
    end

    it "ignores case when comparing alpha-2 codes" do
      purchase = create(:free_purchase)
      purchase.update_columns(country: "United States", ip_country: "United States", card_country: "us")

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["country_mismatches"].values).to all(eq(false))
    end

    it "returns card BIN, type, visual, and expiry" do
      purchase = create(:free_purchase)
      purchase.update_columns(
        card_bin: "424242",
        card_type: "visa",
        card_visual: "**** **** **** 4242",
        card_expiry_month: 11,
        card_expiry_year: 2030
      )

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["card"]).to eq(
        "bin" => "424242",
        "type" => "visa",
        "visual" => "**** **** **** 4242",
        "expiry_month" => 11,
        "expiry_year" => 2030
      )
    end

    it "returns the charge processor and PayPal order ID" do
      purchase = create(:free_purchase)
      purchase.update_columns(charge_processor_id: "paypal", paypal_order_id: "PAY-TEST-123")

      get :show, params: { id: purchase.external_id_numeric }

      payload = response.parsed_body["purchase"]
      expect(payload["charge_processor"]).to eq("paypal")
      expect(payload["paypal_order_id"]).to eq("PAY-TEST-123")
    end

    it "serializes the latest dispute when one exists" do
      purchase = create(:free_purchase)
      create(:dispute, purchase:, state: "lost", reason: Dispute::REASON_FRAUDULENT, charge_processor_dispute_id: "dp_old", created_at: 5.days.ago, lost_at: 1.day.ago)
      newest = create(:dispute, purchase:, state: "formalized", reason: Dispute::REASON_FRAUDULENT, charge_processor_dispute_id: "dp_new", created_at: 1.hour.ago, formalized_at: 30.minutes.ago)

      get :show, params: { id: purchase.external_id_numeric }

      dispute_payload = response.parsed_body["purchase"]["dispute"]
      expect(dispute_payload).to include(
        "id" => newest.external_id,
        "state" => "formalized",
        "reason" => Dispute::REASON_FRAUDULENT,
        "charge_processor_dispute_id" => "dp_new",
        "formalized_at" => newest.formalized_at.as_json,
        "won_at" => nil,
        "lost_at" => nil
      )
    end

    it "returns null dispute when the purchase has none" do
      purchase = create(:free_purchase)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["dispute"]).to be_nil
    end

    it "serializes the early fraud warning when present" do
      purchase = create(:free_purchase)
      efw = create(:early_fraud_warning, purchase:, processor_id: "issfr_test_42", fraud_type: "made_with_stolen_card", charge_risk_level: "highest", actionable: true)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["early_fraud_warning"]).to include(
        "id" => efw.id.to_s,
        "processor_id" => "issfr_test_42",
        "fraud_type" => "made_with_stolen_card",
        "charge_risk_level" => "highest",
        "actionable" => true,
        "resolution" => "unknown",
        "processor_created_at" => efw.processor_created_at.as_json
      )
    end

    it "returns null early fraud warning when the purchase has none" do
      purchase = create(:free_purchase)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["early_fraud_warning"]).to be_nil
    end

    it "serializes the affiliate credit when the purchase used an affiliate" do
      affiliate_user = create(:user)
      affiliate = create(:direct_affiliate, affiliate_user:)
      purchase = create(:free_purchase, affiliate:)
      create(:affiliate_credit, purchase:, affiliate:, affiliate_user:, amount_cents: 750, fee_cents: 50, basis_points: 1000)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["affiliate_credit"]).to eq(
        "amount_cents" => 750,
        "fee_cents" => 50,
        "basis_points" => 1000,
        "affiliate_user_id" => affiliate_user.external_id
      )
    end

    it "returns null affiliate credit when none is attached" do
      purchase = create(:free_purchase)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["affiliate_credit"]).to be_nil
    end

    it "counts purchases sharing the same fingerprint, browser, and IP excluding the current one" do
      shared_fingerprint = "fp_shared"
      shared_browser = "bg_shared"
      shared_ip = "203.0.113.7"
      purchase = create(:free_purchase)
      purchase.update_columns(stripe_fingerprint: shared_fingerprint, browser_guid: shared_browser, ip_address: shared_ip)
      2.times { create(:free_purchase).update_columns(stripe_fingerprint: shared_fingerprint) }
      create(:free_purchase).update_columns(browser_guid: shared_browser)
      3.times { create(:free_purchase).update_columns(ip_address: shared_ip) }
      create(:free_purchase)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["clusters"]).to eq(
        "fingerprint_count" => 2,
        "browser_count" => 1,
        "ip_count" => 3
      )
    end

    it "returns nil cluster counts when the source column is blank" do
      purchase = create(:free_purchase)
      purchase.update_columns(stripe_fingerprint: nil, browser_guid: nil, ip_address: nil)

      get :show, params: { id: purchase.external_id_numeric }

      expect(response.parsed_body["purchase"]["clusters"]).to eq(
        "fingerprint_count" => nil,
        "browser_count" => nil,
        "ip_count" => nil
      )
    end

    it "omits clusters from the search response to avoid N+1 cluster queries" do
      buyer_email = "cluster-search@example.com"
      create(:free_purchase, email: buyer_email)

      get :search, params: { query: buyer_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["purchases"].first).not_to have_key("clusters")
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

  describe "POST resend_receipt" do
    let(:purchase) { create(:free_purchase, email: "buyer@example.com") }

    include_examples "admin api authorization required", :post, :resend_receipt, { id: "123" }

    it "resends the receipt for the given purchase" do
      post :resend_receipt, params: { id: purchase.external_id_numeric.to_s }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        message: "Successfully resent receipt for purchase number #{purchase.external_id_numeric} to #{purchase.email}"
      }.as_json)
      expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("critical")
    end

    it "records an audit log with the purchase target" do
      legacy_admin_token = AdminApiToken.find_by!(token_hash: AdminApiToken.hash_token("test-admin-token"))

      expect do
        post :resend_receipt, params: { id: purchase.external_id_numeric.to_s }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "purchases.resend_receipt",
        target_type: "Purchase",
        target_id: purchase.id,
        target_external_id: purchase.external_id,
        admin_api_token_id: legacy_admin_token.id,
        response_status: 200
      )
    end

    it "returns 404 when the purchase does not exist" do
      post :resend_receipt, params: { id: "999999999" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found" }.as_json)
      expect(SendPurchaseReceiptJob.jobs.size).to eq(0)
    end

    it "returns 404 when the id is not numeric" do
      post :resend_receipt, params: { id: "abc" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found" }.as_json)
      expect(SendPurchaseReceiptJob.jobs.size).to eq(0)
    end
  end

  describe "POST resend_all_receipts" do
    include_examples "admin api authorization required", :post, :resend_all_receipts

    it "returns 400 when email is missing" do
      post :resend_all_receipts

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when no successful purchases exist for the email" do
      post :resend_all_receipts, params: { email: "noone@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "No purchases found for email: noone@example.com" }.as_json)
    end

    it "enqueues a grouped receipt for all successful purchases" do
      buyer_email = "buyer@example.com"
      successful_one = create(:free_purchase, email: buyer_email)
      successful_two = create(:free_purchase, email: buyer_email)
      create(:failed_purchase, email: buyer_email)

      expect(CustomerMailer).to receive(:grouped_receipt).with(match_array([successful_one.id, successful_two.id])).and_call_original

      post :resend_all_receipts, params: { email: buyer_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "message" => "Successfully resent all receipts to #{buyer_email}",
        "count" => 2
      )
    end
  end

  describe "POST refund_taxes" do
    let(:admin_user) { create(:admin_user) }
    let(:purchase) { create(:free_purchase, email: "buyer@example.com") }
    let(:params) { { id: purchase.external_id_numeric.to_s, email: purchase.email } }

    include_examples "admin api authorization required", :post, :refund_taxes, { id: "123", email: "buyer@example.com" }

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :refund_taxes, params: { id: purchase.external_id_numeric.to_s }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when the purchase is missing" do
      post :refund_taxes, params: { id: "999999999", email: "buyer@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found or email doesn't match" }.as_json)
    end

    it "returns 404 when the email does not match the purchase email" do
      post :refund_taxes, params: params.merge(email: "wrong@example.com")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found or email doesn't match" }.as_json)
    end

    context "when the purchase exists" do
      before do
        allow(Purchase).to receive(:find_by_external_id_numeric).with(purchase.external_id_numeric).and_return(purchase)
        purchase.errors.clear
      end

      it "refunds taxes and returns the serialized purchase" do
        expect(purchase).to receive(:refund_gumroad_taxes!).with(refunding_user_id: admin_user.id, note: "tax adjustment", business_vat_id: "VAT123").and_return(true)

        post :refund_taxes, params: params.merge(note: "tax adjustment", business_vat_id: "VAT123")

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include(
          "success" => true,
          "message" => "Successfully refunded taxes for purchase number #{purchase.external_id_numeric}"
        )
        expect(response.parsed_body["purchase"]).to include("id" => purchase.external_id_numeric.to_s)
      end

      it "returns 422 with the purchase error when refund_gumroad_taxes! fails" do
        allow(purchase).to receive(:refund_gumroad_taxes!) do
          purchase.errors.add :base, "Some validation error"
          false
        end

        post :refund_taxes, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ success: false, message: "Some validation error" }.as_json)
      end

      it "returns 422 with a generic message when there are no refundable taxes and no model errors" do
        allow(purchase).to receive(:refund_gumroad_taxes!).and_return(false)

        post :refund_taxes, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ success: false, message: "No refundable taxes available" }.as_json)
      end
    end
  end

  describe "POST reassign" do
    include_examples "admin api authorization required", :post, :reassign

    let(:from_email) { "old@example.com" }
    let(:to_email) { "new@example.com" }
    let(:buyer) { create(:user) }
    let!(:target_user) { create(:user, email: to_email) }
    let!(:merchant_account) { create(:merchant_account, user: nil) }
    let!(:purchase1) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:) }
    let!(:purchase2) { create(:purchase, email: from_email, purchaser: buyer, merchant_account:) }

    it "returns 400 when from is missing" do
      post :reassign, params: { to: to_email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "Both 'from' and 'to' email addresses are required" }.as_json)
    end

    it "returns 400 when to is missing" do
      post :reassign, params: { from: from_email }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "Both 'from' and 'to' email addresses are required" }.as_json)
    end

    it "returns 404 when no purchases match the from email" do
      post :reassign, params: { from: "nobody@example.com", to: to_email }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "No purchases found for email: nobody@example.com" }.as_json)
    end

    it "reassigns purchases via Purchase::ReassignByEmailService and returns the result" do
      post :reassign, params: { from: from_email, to: to_email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["count"]).to eq(2)
      expect(response.parsed_body["reassigned_purchase_ids"]).to match_array([purchase1.id, purchase2.id])
      expect(response.parsed_body["message"]).to include("Successfully reassigned 2 purchases from #{from_email} to #{to_email}")
      expect(purchase1.reload.email).to eq(to_email)
      expect(purchase1.purchaser_id).to eq(target_user.id)
      expect(purchase2.reload.email).to eq(to_email)
    end

    it "redacts the reassignment email addresses from the audit snapshot" do
      post :reassign, params: { from: from_email, to: to_email }

      expect(response).to have_http_status(:ok)
      expect(AdminApiAuditLog.last.params_snapshot).to include(
        "from" => "[REDACTED]",
        "to" => "[REDACTED]"
      )
    end

    it "returns 422 when every purchase save fails" do
      allow_any_instance_of(Purchase).to receive(:save).and_return(false)

      post :reassign, params: { from: from_email, to: to_email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({ success: false, message: "No purchases were reassigned" }.as_json)
    end

    it "returns 422 when from and to emails are the same" do
      post :reassign, params: { from: from_email, to: from_email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({ success: false, message: "from and to emails are the same" }.as_json)
    end
  end

  describe "POST cancel_subscription" do
    let(:admin_user) { create(:admin_user) }
    let(:purchase) { create(:free_purchase, email: "buyer@example.com") }
    let(:params) { { id: purchase.external_id_numeric.to_s, email: purchase.email } }

    include_examples "admin api authorization required", :post, :cancel_subscription, { id: "123", email: "buyer@example.com" }

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :cancel_subscription, params: { id: purchase.external_id_numeric.to_s }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when the purchase is missing" do
      post :cancel_subscription, params: { id: "999999999", email: "buyer@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found or email doesn't match" }.as_json)
    end

    it "returns 404 when the email does not match the purchase email" do
      post :cancel_subscription, params: params.merge(email: "wrong@example.com")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found or email doesn't match" }.as_json)
    end

    it "returns 422 when the purchase has no subscription" do
      post :cancel_subscription, params: params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase has no subscription" }.as_json)
    end

    context "when the purchase has a subscription" do
      let(:subscription) { instance_double(Subscription, deactivated?: false, cancelled_at: nil) }

      before do
        allow(Purchase).to receive(:find_by_external_id_numeric).with(purchase.external_id_numeric).and_return(purchase)
        allow(purchase).to receive(:subscription).and_return(subscription)
      end

      it "cancels the subscription as buyer-initiated by default" do
        cancelled_at = Time.current
        expect(subscription).to receive(:cancel!).with(by_seller: false, by_admin: true) do
          allow(subscription).to receive(:cancelled_at).and_return(cancelled_at)
          allow(subscription).to receive(:cancelled_by_buyer?).and_return(true)
          allow(subscription).to receive(:cancelled_by_admin?).and_return(true)
        end

        post :cancel_subscription, params: params

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["message"]).to eq("Successfully cancelled subscription for purchase number #{purchase.external_id_numeric}")
        expect(response.parsed_body["cancelled_at"]).to eq(cancelled_at.as_json)
        expect(response.parsed_body["cancelled_by_admin"]).to be(true)
        expect(response.parsed_body["cancelled_by_seller"]).to be(false)
      end

      it "cancels with seller-initiated semantics when by_seller is true" do
        expect(subscription).to receive(:cancel!).with(by_seller: true, by_admin: true) do
          allow(subscription).to receive(:cancelled_at).and_return(Time.current)
          allow(subscription).to receive(:cancelled_by_buyer?).and_return(false)
          allow(subscription).to receive(:cancelled_by_admin?).and_return(true)
        end

        post :cancel_subscription, params: params.merge(by_seller: "true")

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["cancelled_by_seller"]).to be(true)
      end

      it "short-circuits when the subscription is already pending cancellation" do
        cancelled_at = 1.day.from_now
        allow(subscription).to receive(:cancelled_at).and_return(cancelled_at)
        allow(subscription).to receive(:cancelled_by_admin?).and_return(false)
        expect(subscription).not_to receive(:cancel!)

        post :cancel_subscription, params: params

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include(
          "success" => true,
          "status" => "already_cancelled",
          "message" => "Subscription is already cancelled",
          "cancelled_at" => cancelled_at.as_json,
          "cancelled_by_admin" => false
        )
      end

      it "returns already_inactive with the termination reason when the subscription is deactivated via failed payment" do
        deactivated_at = 1.day.ago
        allow(subscription).to receive(:deactivated?).and_return(true)
        allow(subscription).to receive(:deactivated_at).and_return(deactivated_at)
        allow(subscription).to receive(:termination_reason).and_return("failed_payment")
        expect(subscription).not_to receive(:cancel!)

        post :cancel_subscription, params: params

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include(
          "success" => true,
          "status" => "already_inactive",
          "message" => "Subscription is no longer active",
          "termination_reason" => "failed_payment",
          "deactivated_at" => deactivated_at.as_json
        )
      end

      it "returns already_inactive when the subscription ended naturally" do
        allow(subscription).to receive(:deactivated?).and_return(true)
        allow(subscription).to receive(:deactivated_at).and_return(2.days.ago)
        allow(subscription).to receive(:termination_reason).and_return("fixed_subscription_period_ended")
        expect(subscription).not_to receive(:cancel!)

        post :cancel_subscription, params: params

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["status"]).to eq("already_inactive")
        expect(response.parsed_body["termination_reason"]).to eq("fixed_subscription_period_ended")
      end
    end
  end

  describe "POST block_buyer" do
    let(:admin_user) { create(:admin_user) }
    let(:purchase) { create(:free_purchase, email: "buyer@example.com") }
    let(:params) { { id: purchase.external_id_numeric.to_s, email: purchase.email } }

    include_examples "admin api authorization required", :post, :block_buyer, { id: "123", email: "buyer@example.com" }

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :block_buyer, params: { id: purchase.external_id_numeric.to_s }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when the purchase is missing" do
      post :block_buyer, params: { id: "999999999", email: "buyer@example.com" }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when the email does not match" do
      post :block_buyer, params: params.merge(email: "wrong@example.com")

      expect(response).to have_http_status(:not_found)
    end

    it "blocks the buyer and flips buyer_blocked? to true" do
      expect { post :block_buyer, params: params }.to change { purchase.reload.buyer_blocked? }.from(false).to(true)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["message"]).to eq("Successfully blocked buyer for purchase number #{purchase.external_id_numeric}")
      expect(purchase.reload.is_buyer_blocked_by_admin?).to be(true)
    end

    it "creates an audit comment with the provided comment_content" do
      post :block_buyer, params: params.merge(comment_content: "Refund abuse")

      expect(response).to have_http_status(:ok)
      expect(purchase.comments.where(author_id: admin_user.id, content: "Refund abuse").count).to eq(1)
    end

    it "creates a default audit comment when comment_content is omitted" do
      post :block_buyer, params: params

      expect(response).to have_http_status(:ok)
      expect(purchase.comments.where(author_id: admin_user.id).where("content LIKE ?", "Buyer blocked%").count).to eq(1)
    end

    it "short-circuits when the buyer is already blocked by admin on this purchase" do
      purchase.block_buyer!(blocking_user_id: admin_user.id)
      expect(purchase.reload.is_buyer_blocked_by_admin?).to be(true)
      expect_any_instance_of(Purchase).not_to receive(:block_buyer!)

      post :block_buyer, params: params

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "status" => "already_blocked",
        "message" => "Buyer is already blocked by admin"
      )
    end

    it "does not short-circuit when the buyer was auto-blocked without admin attribution" do
      previous_purchase = create(:free_purchase, email: purchase.email)
      previous_purchase.block_buyer!(blocking_user_id: nil, comment_content: "Auto-blocked: chargeback rate")
      expect(purchase.reload.buyer_blocked?).to be(true)
      expect(purchase.is_buyer_blocked_by_admin?).to be(false)

      expect { post :block_buyer, params: params }
        .to change { purchase.reload.is_buyer_blocked_by_admin? }.from(false).to(true)
        .and change { purchase.comments.where(author_id: admin_user.id).count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body).not_to have_key("status")
    end

    it "re-establishes the block when the admin flag is stale and BlockedObject was cleared elsewhere" do
      purchase.block_buyer!(blocking_user_id: admin_user.id)
      purchase.unblock_buyer!
      purchase.update!(is_buyer_blocked_by_admin: true)
      expect(purchase.reload.is_buyer_blocked_by_admin?).to be(true)
      expect(purchase.buyer_blocked?).to be(false)

      expect { post :block_buyer, params: params }
        .to change { purchase.reload.buyer_blocked? }.from(false).to(true)
        .and change { purchase.comments.where(author_id: admin_user.id).count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body).not_to have_key("status")
    end
  end

  describe "POST unblock_buyer" do
    let(:admin_user) { create(:admin_user) }
    let(:purchase) { create(:free_purchase, email: "buyer@example.com") }
    let(:params) { { id: purchase.external_id_numeric.to_s, email: purchase.email } }

    include_examples "admin api authorization required", :post, :unblock_buyer, { id: "123", email: "buyer@example.com" }

    before { stub_const("GUMROAD_ADMIN_ID", admin_user.id) }

    it "returns 400 when email is missing" do
      post :unblock_buyer, params: { id: purchase.external_id_numeric.to_s }

      expect(response).to have_http_status(:bad_request)
    end

    it "returns 404 when the purchase is missing" do
      post :unblock_buyer, params: { id: "999999999", email: "buyer@example.com" }

      expect(response).to have_http_status(:not_found)
    end

    it "unblocks the buyer, flips buyer_blocked? to false, and creates an audit comment" do
      purchase.block_buyer!(blocking_user_id: admin_user.id)
      expect(purchase.reload.buyer_blocked?).to be(true)

      expect { post :unblock_buyer, params: params }
        .to change { purchase.comments.where(author_id: admin_user.id, content: "Buyer unblocked by Admin").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["message"]).to eq("Successfully unblocked buyer for purchase number #{purchase.external_id_numeric}")
      expect(purchase.reload.buyer_blocked?).to be(false)
      expect(purchase.reload.is_buyer_blocked_by_admin?).to be(false)
    end

    it "creates an unblock comment on the purchaser when present" do
      buyer = create(:user, email: "buyer@example.com")
      purchase.update!(purchaser: buyer)
      purchase.block_buyer!(blocking_user_id: admin_user.id)

      expect { post :unblock_buyer, params: params }
        .to change { buyer.reload.comments.where(author_id: admin_user.id, content: "Buyer unblocked by Admin").count }.by(1)
    end

    it "short-circuits when the buyer is not blocked" do
      expect_any_instance_of(Purchase).not_to receive(:unblock_buyer!)

      post :unblock_buyer, params: params

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "success" => true,
        "status" => "not_blocked",
        "message" => "Buyer is not blocked"
      )
    end

    it "clears the stale admin flag when BlockedObject was cleared elsewhere" do
      purchase.block_buyer!(blocking_user_id: admin_user.id)
      purchase.unblock_buyer!
      purchase.update!(is_buyer_blocked_by_admin: true)
      expect(purchase.reload.is_buyer_blocked_by_admin?).to be(true)
      expect(purchase.buyer_blocked?).to be(false)

      expect { post :unblock_buyer, params: params }
        .to change { purchase.reload.is_buyer_blocked_by_admin? }.from(true).to(false)
        .and change { purchase.comments.where(author_id: admin_user.id, content: "Buyer unblocked by Admin").count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body).not_to have_key("status")
    end
  end

  describe "POST refund_for_fraud" do
    let(:admin_user) { create(:admin_user) }
    let(:purchase) { create(:free_purchase, email: "buyer@example.com") }
    let(:params) { { id: purchase.external_id_numeric.to_s, email: purchase.email } }

    include_examples "admin api authorization required", :post, :refund_for_fraud, { id: "123", email: "buyer@example.com" }

    it "returns 400 when email is missing" do
      post :refund_for_fraud, params: { id: purchase.external_id_numeric.to_s }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "email is required" }.as_json)
    end

    it "returns 404 when the purchase is missing" do
      post :refund_for_fraud, params: { id: "999999999", email: "buyer@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "Purchase not found or email doesn't match" }.as_json)
    end

    it "returns 404 when the email does not match" do
      post :refund_for_fraud, params: params.merge(email: "wrong@example.com")

      expect(response).to have_http_status(:not_found)
    end

    context "when the purchase exists" do
      before do
        allow(Purchase).to receive(:find_by_external_id_numeric).with(purchase.external_id_numeric).and_return(purchase)
        allow(purchase).to receive(:stripe_transaction_id).and_return("ch_test")
        allow(purchase).to receive(:amount_refundable_cents).and_return(1000)
        purchase.errors.clear
      end

      it "returns 422 when the purchase is already fully refunded" do
        allow(purchase).to receive(:stripe_refunded).and_return(true)
        expect(purchase).not_to receive(:refund_for_fraud_and_block_buyer!)

        post :refund_for_fraud, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ success: false, message: "Purchase has already been fully refunded" }.as_json)
      end

      it "returns 422 when the purchase has no charge to refund" do
        allow(purchase).to receive(:stripe_transaction_id).and_return(nil)
        expect(purchase).not_to receive(:refund_for_fraud_and_block_buyer!)

        post :refund_for_fraud, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ success: false, message: "Purchase has no charge to refund" }.as_json)
      end

      it "returns 422 when the purchase has no remaining refundable amount" do
        allow(purchase).to receive(:amount_refundable_cents).and_return(0)
        expect(purchase).not_to receive(:refund_for_fraud_and_block_buyer!)

        post :refund_for_fraud, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ success: false, message: "Purchase has no charge to refund" }.as_json)
      end

      it "delegates to refund_for_fraud_and_block_buyer! and returns the serialized purchase" do
        expect(purchase).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id).and_return(true)
        cancelled_at = Time.current
        subscription = instance_double(Subscription, cancelled_at: cancelled_at, price: nil)
        allow(purchase).to receive(:subscription).and_return(subscription)

        post :refund_for_fraud, params: params

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["message"]).to eq("Successfully refunded purchase number #{purchase.external_id_numeric} for fraud and blocked the buyer")
        expect(response.parsed_body["purchase"]).to include("id" => purchase.external_id_numeric.to_s)
        expect(response.parsed_body["subscription_cancelled"]).to be(true)
      end

      it "returns subscription_cancelled: false when there is no subscription" do
        expect(purchase).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id).and_return(true)
        allow(purchase).to receive(:subscription).and_return(nil)

        post :refund_for_fraud, params: params

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["subscription_cancelled"]).to be(false)
      end

      it "returns 422 with the model error when refund_for_fraud_and_block_buyer! fails" do
        allow(purchase).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id) do
          purchase.errors.add :base, "Refund amount cannot be greater than the purchase price."
          false
        end

        post :refund_for_fraud, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ success: false, message: "Refund amount cannot be greater than the purchase price." }.as_json)
      end

      it "returns 422 with a generic message when refund_for_fraud_and_block_buyer! fails without errors" do
        allow(purchase).to receive(:refund_for_fraud_and_block_buyer!).with(admin_user.id).and_return(false)

        post :refund_for_fraud, params: params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ success: false, message: "Refund-for-fraud failed for purchase number #{purchase.external_id_numeric}" }.as_json)
      end
    end
  end
end
