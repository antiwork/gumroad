# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::ScheduledPayoutsController do
  let(:user) { create(:compliant_user) }

  before do
    stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
  end

  describe "GET index" do
    include_examples "admin api authorization required", :get, :index

    let(:merchant_account) { create(:merchant_account, user: nil) }

    let(:enrichment_keys) do
      %w[
        product_count
        incoming_affiliate_count
        risk_state
        top_categories
        unpaid_balance_cents
        unpaid_balance_formatted
      ]
    end

    it "returns scheduled payouts ordered by id desc" do
      first = create(:scheduled_payout, user:)
      second = create(:scheduled_payout, user: create(:user))

      get :index

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body
      expect(payload["success"]).to be(true)
      expect(payload["scheduled_payouts"].map { _1["external_id"] }).to eq([second.external_id, first.external_id])
    end

    it "filters by status when provided" do
      flagged = create(:scheduled_payout, user:, status: "flagged")
      create(:scheduled_payout, user: create(:user), status: "pending")

      get :index, params: { status: "flagged" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scheduled_payouts"].map { _1["external_id"] }).to eq([flagged.external_id])
    end

    it "returns 400 when status is invalid" do
      get :index, params: { status: "bogus" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "status is invalid" }.as_json)
    end

    it "caps the limit at MAX_LIMIT" do
      get :index, params: { limit: 9999 }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["limit"]).to eq(50)
    end

    it "uses the default limit when limit is missing or non-positive" do
      get :index

      expect(response.parsed_body["limit"]).to eq(20)

      get :index, params: { limit: 0 }

      expect(response.parsed_body["limit"]).to eq(20)
    end

    it "filters by user_id when provided" do
      mine = create(:scheduled_payout, user:)
      create(:scheduled_payout, user: create(:user))

      get :index, params: { user_id: user.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scheduled_payouts"].map { _1["external_id"] }).to eq([mine.external_id])
    end

    it "filters by email when provided" do
      mine = create(:scheduled_payout, user:)
      create(:scheduled_payout, user: create(:user))

      get :index, params: { email: user.email }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scheduled_payouts"].map { _1["external_id"] }).to eq([mine.external_id])
    end

    it "returns 404 when the requested user does not exist" do
      get :index, params: { email: "missing@example.com" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ success: false, message: "User not found" }.as_json)
    end

    it "filters by an array of statuses" do
      held = create(:scheduled_payout, user:, status: "held")
      flagged = create(:scheduled_payout, user: create(:user), status: "flagged")
      create(:scheduled_payout, user: create(:user), status: "pending")

      get :index, params: { status: ["held", "flagged"] }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scheduled_payouts"].map { _1["external_id"] }).to match_array([held.external_id, flagged.external_id])
    end

    it "returns 400 when any status in the array is invalid" do
      get :index, params: { status: ["held", "bogus"] }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq({ success: false, message: "status is invalid" }.as_json)
    end

    it "combines user and status filters" do
      held_mine = create(:scheduled_payout, user:, status: "held")
      create(:scheduled_payout, user: create(:user), status: "held")

      get :index, params: { user_id: user.external_id, status: ["held", "flagged"] }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scheduled_payouts"].map { _1["external_id"] }).to eq([held_mine.external_id])
    end

    it "includes enrichment keys for each scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)

      get :index

      row = response.parsed_body["scheduled_payouts"].find { _1["external_id"] == scheduled_payout.external_id }
      expect(row.keys).to include(*enrichment_keys)
      expect(row["risk_state"]).to eq(Admin::UserRiskStatePresenter.new(user).props.as_json)
    end

    it "reports alive product count" do
      seller = create(:compliant_user)
      create_list(:product, 2, user: seller)
      create(:product, user: seller, deleted_at: Time.current)
      scheduled_payout = create(:scheduled_payout, user: seller)

      get :index

      row = response.parsed_body["scheduled_payouts"].find { _1["external_id"] == scheduled_payout.external_id }
      expect(row["product_count"]).to eq(2)
    end

    it "reports incoming affiliate count without global or deleted affiliates" do
      seller = create(:compliant_user)
      create_list(:direct_affiliate, 2, seller:)
      create(:collaborator, seller:)
      create(:direct_affiliate, seller:, deleted_at: Time.current)
      seller.global_affiliate.update_column(:seller_id, seller.id)
      scheduled_payout = create(:scheduled_payout, user: seller)

      get :index

      row = response.parsed_body["scheduled_payouts"].find { _1["external_id"] == scheduled_payout.external_id }
      expect(row["incoming_affiliate_count"]).to eq(3)
    end

    it "reports top categories by alive product count" do
      seller = create(:compliant_user)
      taxonomy_a = create(:taxonomy, slug: "taxonomy-a")
      taxonomy_b = create(:taxonomy, slug: "taxonomy-b")
      create_list(:product, 2, user: seller, taxonomy: taxonomy_a)
      create(:product, user: seller, taxonomy: taxonomy_b)
      scheduled_payout = create(:scheduled_payout, user: seller)

      get :index

      row = response.parsed_body["scheduled_payouts"].find { _1["external_id"] == scheduled_payout.external_id }
      expected_categories = [
        { "slug" => "taxonomy-a", "product_count" => 2 },
        { "slug" => "taxonomy-b", "product_count" => 1 }
      ]
      expect(row["top_categories"]).to eq(expected_categories)
    end

    it "reports unpaid balance" do
      seller = create(:compliant_user)
      create(:balance, user: seller, merchant_account:, amount_cents: 12_345, state: "unpaid")
      create(:balance, user: seller, merchant_account:, amount_cents: 9_999, state: "paid")
      scheduled_payout = create(:scheduled_payout, user: seller)

      get :index

      row = response.parsed_body["scheduled_payouts"].find { _1["external_id"] == scheduled_payout.external_id }
      expect(row["unpaid_balance_cents"]).to eq(12_345)
      expect(row["unpaid_balance_formatted"]).to eq("$123.45")
    end

    it "keeps scheduled payout list enrichment queries bounded" do
      taxonomy = create(:taxonomy)
      5.times do
        seller = create(:compliant_user)
        create(:product, user: seller, taxonomy:)
        create(:direct_affiliate, seller:)
        create(:balance, user: seller, merchant_account:, amount_cents: 1_00)
        create(:comment, commentable: seller, comment_type: Comment::COMMENT_TYPE_COMPLIANT)
        create(:scheduled_payout, user: seller)
      end

      queries = sql_queries_for { get :index, params: { limit: 5 } }

      expect(response).to have_http_status(:ok)
      expect(queries.count).to be <= 14
    end
  end

  describe "POST execute" do
    include_examples "admin api authorization required", :post, :execute, { id: "abc" }

    it "returns 404 when the scheduled payout is not found" do
      post :execute, params: { id: "missing" }

      expect(response).to have_http_status(:not_found)
    end

    it "executes a pending scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)
      allow_any_instance_of(ScheduledPayout).to receive(:execute!).and_return(:executed)

      post :execute, params: { id: scheduled_payout.external_id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("success" => true, "result" => "executed")
      expect(response.parsed_body["scheduled_payout"].keys).to include(
        "product_count",
        "incoming_affiliate_count",
        "risk_state",
        "top_categories",
        "unpaid_balance_cents",
        "unpaid_balance_formatted"
      )
    end

    it "promotes a flagged scheduled payout to pending before executing" do
      scheduled_payout = create(:scheduled_payout, user:, status: "flagged")
      allow_any_instance_of(ScheduledPayout).to receive(:execute!).and_return(:executed)

      expect do
        post :execute, params: { id: scheduled_payout.external_id }
      end.to change { scheduled_payout.reload.status }.from("flagged").to("pending")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["result"]).to eq("executed")
    end

    it "returns 422 when the scheduled payout is already executed" do
      scheduled_payout = create(:scheduled_payout, user:, status: "executed")

      post :execute, params: { id: scheduled_payout.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("Cannot execute a executed scheduled payout.")
    end

    it "returns 422 and the error message when execute! raises" do
      scheduled_payout = create(:scheduled_payout, user:)
      allow_any_instance_of(ScheduledPayout).to receive(:execute!).and_raise("nope")

      post :execute, params: { id: scheduled_payout.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("success" => false, "message" => "nope")
    end

    it "writes an admin audit log targeting the scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)
      allow_any_instance_of(ScheduledPayout).to receive(:execute!).and_return(:executed)

      expect do
        post :execute, params: { id: scheduled_payout.external_id }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "scheduled_payouts.execute",
        target_type: "ScheduledPayout",
        target_id: scheduled_payout.id,
        target_external_id: scheduled_payout.external_id,
        response_status: 200
      )
    end
  end

  describe "POST cancel" do
    include_examples "admin api authorization required", :post, :cancel, { id: "abc" }

    it "returns 404 when the scheduled payout is not found" do
      post :cancel, params: { id: "missing" }

      expect(response).to have_http_status(:not_found)
    end

    it "cancels a pending scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)

      expect do
        post :cancel, params: { id: scheduled_payout.external_id }
      end.to change { scheduled_payout.reload.status }.from("pending").to("cancelled")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["scheduled_payout"].keys).to include(
        "product_count",
        "incoming_affiliate_count",
        "risk_state",
        "top_categories",
        "unpaid_balance_cents",
        "unpaid_balance_formatted"
      )
    end

    it "returns 422 and the error message when cancel! raises" do
      scheduled_payout = create(:scheduled_payout, user:)
      allow_any_instance_of(ScheduledPayout).to receive(:cancel!).and_raise("already executed")

      post :cancel, params: { id: scheduled_payout.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include("success" => false, "message" => "already executed")
    end

    it "writes an admin audit log targeting the scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user:)

      expect do
        post :cancel, params: { id: scheduled_payout.external_id }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "scheduled_payouts.cancel",
        target_type: "ScheduledPayout",
        target_id: scheduled_payout.id,
        response_status: 200
      )
    end
  end

  def sql_queries_for(&block)
    queries = []
    counter = lambda do |*, payload|
      next if payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    queries
  end
end
