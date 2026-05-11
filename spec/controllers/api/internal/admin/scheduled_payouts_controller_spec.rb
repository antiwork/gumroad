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
end
