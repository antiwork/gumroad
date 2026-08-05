# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::StrandedBuyersController do
  let(:admin_user) { create(:admin_user) }

  it "inherits from Api::Internal::Admin::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Admin::BaseController)
  end

  describe "GET scan" do
    # The shared examples' before block also provisions the admin token + header for this block.
    include_examples "admin api authorization required", :get, :scan

    it "returns the scan's candidates with external ids and block summaries" do
      buyer = create(:user, email: "stranded@example.com")
      scan = {
        stranded: [{
          email: "stranded@example.com",
          purchaser_external_id: buyer.external_id,
          settled_purchases: 5,
          blocked_at: Time.utc(2026, 1, 2),
          block_type: "browser_guid",
          failed_at: Time.utc(2026, 8, 1),
          attempts: 3,
        }],
        truncated: false,
      }
      allow(Risk::StrandedBuyerScanService).to receive(:call).and_return(scan)

      get :scan

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["truncated"]).to be(false)
      expect(body["count"]).to eq(1)
      candidate = body["candidates"].sole
      expect(candidate["email"]).to eq("stranded@example.com")
      expect(candidate["user_id"]).to eq(buyer.external_id)
      expect(candidate["settled_purchases"]).to eq(5)
      expect(candidate["block_type"]).to eq("browser_guid")
      expect(candidate["attempts"]).to eq(3)
    end

    it "caps the returned candidates and reports the uncapped total" do
      entries = 3.times.map do |index|
        { email: "buyer#{index}@example.com", purchaser_external_id: nil, settled_purchases: 3,
          blocked_at: Time.current, block_type: "browser_guid", failed_at: Time.current, attempts: 1 }
      end
      allow(Risk::StrandedBuyerScanService).to receive(:call).and_return({ stranded: entries, truncated: true })

      get :scan, params: { limit: 2 }

      body = response.parsed_body
      expect(body["candidates"].size).to eq(2)
      expect(body["count"]).to eq(2)
      expect(body["total"]).to eq(3)
      expect(body["truncated"]).to be(true)
    end
  end

  describe "POST recover" do
    include_examples "admin api authorization required", :post, :recover, { email: "buyer@example.com" }

    let(:buyer_email) { "stranded-buyer@example.com" }
    let(:browser_guid) { "guid-recover-endpoint" }

    def strand_buyer!
      create_list(:purchase, Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY,
                  email: buyer_email, purchase_state: "successful", created_at: 6.months.ago)
      create(:purchase, email: buyer_email, browser_guid:, purchase_state: "failed",
                        error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID, created_at: 1.day.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    end

    it "requires an identifier" do
      post :recover
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to eq("email or user_id is required")
    end

    it "defaults to a dry run" do
      strand_buyer!

      expect do
        post :recover, params: { email: buyer_email }
      end.not_to change { PlatformBlock.active.count }

      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["verdict"]).to eq("cleared")
      expect(body["dry_run"]).to be(true)
      expect(body["attribution"]["rule"]).to eq("single_decline_auto_block")
      expect(body["cleared"].sole["object_value"]).to eq(browser_guid)
    end

    it "clears when dry_run is false and audits the write" do
      strand_buyer!

      expect do
        post :recover, params: { email: buyer_email, dry_run: false }
      end.to change { PlatformBlock.active.count }.from(1).to(0)
         .and change { AdminApiAuditLog.count }.by(1)

      body = response.parsed_body
      expect(body["verdict"]).to eq("cleared")
      expect(body["dry_run"]).to be(false)
      expect(AdminApiAuditLog.last.action).to eq("stranded_buyers.recover")
    end

    it "resolves the buyer by user external id" do
      strand_buyer!
      buyer = create(:user, email: buyer_email)

      post :recover, params: { user_id: buyer.external_id, dry_run: false }

      expect(response.parsed_body["verdict"]).to eq("cleared")
      expect(PlatformBlock.active.count).to eq(0)
    end

    it "returns the escalate verdict without touching anything" do
      strand_buyer!
      other_admin = create(:admin_user)
      PlatformBlock.last.update!(blocked_by: other_admin.id)

      expect do
        post :recover, params: { email: buyer_email, dry_run: false }
      end.not_to change { PlatformBlock.active.count }

      body = response.parsed_body
      expect(body["verdict"]).to eq("escalate")
      expect(body["reason"]).to eq("human_authored_block")
    end

    it "surfaces a verification failure as unprocessable" do
      strand_buyer!
      allow(Risk::StrandedBuyerRecoveryService).to receive(:call)
        .and_raise(Risk::StrandedBuyerRecoveryService::VerificationFailedError, "1 block(s) still active after clearing")

      post :recover, params: { email: buyer_email, dry_run: false }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to include("still active")
    end
  end
end
