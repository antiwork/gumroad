# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::ScheduledPayoutsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:user) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    it "lists scheduled payouts" do
      scheduled_payout = create(:scheduled_payout, user: user, action: "payout", created_by: admin_user)

      get :index

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/ScheduledPayouts/Index")
      expect(inertia.props[:scheduled_payouts].length).to eq(1)
      expect(inertia.props[:scheduled_payouts].first[:external_id]).to eq(scheduled_payout.external_id)
    end

    it "filters by status" do
      create(:scheduled_payout, status: "pending")
      create(:scheduled_payout, status: "executed")

      get :index, params: { status: "pending" }

      expect(inertia.props[:scheduled_payouts].length).to eq(1)
      expect(inertia.props[:scheduled_payouts].first[:status]).to eq("pending")
    end

    it "paginates results" do
      22.times { create(:scheduled_payout) }

      get :index

      expect(inertia.props[:scheduled_payouts].length).to eq(20)
      expect(inertia.props[:pagination][:pages]).to eq(2)
    end
  end

  describe "POST execute" do
    let(:suspended_user) { create(:user, user_risk_state: "suspended_for_fraud") }

    it "executes a pending scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user: suspended_user, action: "refund", status: "pending", created_by: admin_user)

      post :execute, params: { external_id: scheduled_payout.external_id }

      expect(response.parsed_body["success"]).to be(true)
      expect(scheduled_payout.reload.status).to eq("executed")
      expect(RefundUnpaidPurchasesWorker.jobs.size).to eq(1)
    end

    it "executes a flagged scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user: suspended_user, action: "refund", status: "flagged", created_by: admin_user)

      post :execute, params: { external_id: scheduled_payout.external_id }

      expect(response.parsed_body["success"]).to be(true)
      expect(scheduled_payout.reload.status).to eq("executed")
    end

    it "returns flagged message when payout is re-flagged due to chargebacks" do
      product = create(:product, user: suspended_user)
      create(:free_purchase, link: product, chargeback_date: 2.days.ago)
      scheduled_payout = create(:scheduled_payout, user: suspended_user, action: "payout", status: "pending", created_by: admin_user)

      post :execute, params: { external_id: scheduled_payout.external_id }

      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["message"]).to eq("Payout was flagged for review instead of executing.")
      expect(scheduled_payout.reload.status).to eq("flagged")
    end

    it "rejects executing a cancelled scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user: user, status: "cancelled")

      post :execute, params: { external_id: scheduled_payout.external_id }

      expect(response.parsed_body["success"]).to be(false)
    end
  end

  describe "POST cancel" do
    it "cancels a pending scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user: user, status: "pending")

      post :cancel, params: { external_id: scheduled_payout.external_id }

      expect(response.parsed_body["success"]).to be(true)
      expect(scheduled_payout.reload.status).to eq("cancelled")
    end

    it "cancels a flagged scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user: user, status: "flagged")

      post :cancel, params: { external_id: scheduled_payout.external_id }

      expect(response.parsed_body["success"]).to be(true)
      expect(scheduled_payout.reload.status).to eq("cancelled")
    end

    it "rejects cancelling an executed scheduled payout" do
      scheduled_payout = create(:scheduled_payout, user: user, status: "executed")

      post :cancel, params: { external_id: scheduled_payout.external_id }

      expect(response.parsed_body["success"]).to be(false)
    end
  end
end
