# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::StripeCourtOrderNoticesController do
  let(:admin_user) { create(:admin_user) }
  let(:seller) { create(:user, email: "seller@example.com", name: "Test Seller") }
  let(:notice_params) do
    {
      stripe_account_id: "acct_1TestCourtOrder04",
      firm_name: "Example Legal LLP",
      firm_email: "notices@example.com",
      notice_key: "test-court-order-notice-0004",
    }
  end

  it "inherits from Api::Internal::Admin::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Admin::BaseController)
  end

  describe "POST create" do
    include_examples "admin api authorization required", :post, :create

    before do
      create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_1TestCourtOrder04")
      @per_actor_token = AdminApiToken.mint!(actor_user_id: admin_user.id)
      request.headers["Authorization"] = "Bearer #{@per_actor_token}"
    end

    it "rejects the legacy shared admin token" do
      request.headers["Authorization"] = "Bearer test-admin-token"

      post :create, params: notice_params.merge(dry_run: false)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["message"]).to eq("per-actor admin token is required")
      expect(Comment.count).to eq(0)
    end

    it "defaults to a dry run that returns the seller and the rendered email" do
      writes = []
      callback = ->(*, payload) { writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE|REPLACE)/i) }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { post :create, params: notice_params }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["status"]).to eq("dry_run")
      expect(body["already_sent"]).to be(false)
      expect(body["user"]).to eq("user_id" => seller.external_id, "email" => "seller@example.com", "name" => "Test Seller")
      expect(body["comment_id"]).to be_nil
      expect(body["email"]).to include(
        "from" => "Gumroad <#{ApplicationMailer::NOREPLY_EMAIL}>",
        "reply_to" => [ApplicationMailer::SUPPORT_EMAIL],
        "to" => ["seller@example.com"],
        "subject" => "Important notice regarding your Gumroad payment account"
      )
      expect(body["email"]["html_body"]).to include("Law firm: Example Legal LLP")
      expect(writes).to eq([])
      expect(Comment.count).to eq(0)
      expect(AdminApiAuditLog.count).to eq(0)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(0)
    end

    it "treats a blank dry_run as a dry run" do
      post :create, params: notice_params.merge(dry_run: "")

      expect(response.parsed_body["status"]).to eq("dry_run")
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(0)
    end

    it "queues the email, records the comment and audits the write when dry_run is false" do
      freeze_time
      post :create, params: notice_params.merge(dry_run: false)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      comment = seller.comments.sole
      expect(body).to include("success" => true, "status" => "queued", "comment_id" => comment.external_id)
      expect(body["user"]).to eq("user_id" => seller.external_id, "email" => "seller@example.com", "name" => "Test Seller")
      expect(body["comment"]["content"]).to eq(comment.content)
      expect(comment.author_id).to eq(admin_user.id)
      expect(StripeCourtOrderNoticeEmailJob).to have_enqueued_sidekiq_job(seller.id, comment.id, "Example Legal LLP", "notices@example.com")
      audit_log = AdminApiAuditLog.sole
      expect(audit_log.action).to eq("stripe_court_order_notices.create")
      expect(audit_log.target_id).to eq(seller.id)
      expect(AdminApiToken.authenticate(@per_actor_token).last_used_at).to eq(Time.current)
    end

    it "answers already_sent for a repeat, and a later dry run reports it" do
      post :create, params: notice_params.merge(dry_run: false)
      first_comment_id = response.parsed_body["comment_id"]

      post :create, params: notice_params.merge(dry_run: false)

      expect(response.parsed_body).to include("status" => "already_sent", "comment_id" => first_comment_id)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)

      post :create, params: notice_params

      expect(response.parsed_body).to include("status" => "dry_run", "already_sent" => true, "comment_id" => first_comment_id)
    end

    it "sends for a JSON body with a boolean false dry_run" do
      post :create, params: notice_params.merge(dry_run: false), as: :json

      expect(response.parsed_body["status"]).to eq("queued")
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)
    end

    it "returns 503 and records nothing when the job push is refused" do
      allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_return(nil)

      post :create, params: notice_params.merge(dry_run: false)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq("success" => false, "message" => "The notice email could not be queued")
      expect(Comment.count).to eq(0)
    end

    it "returns 409 and queues nothing when the notice key is reused for a different notice" do
      post :create, params: notice_params.merge(dry_run: false)

      post :create, params: notice_params.merge(dry_run: false, firm_name: "Other Legal LLP")

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["message"]).to eq("notice_key was already used for a different notice")
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)
      expect(AdminApiAuditLog.last.response_status).to eq(409)
    end

    it "returns 422 for a malformed Stripe account id" do
      post :create, params: notice_params.merge(stripe_account_id: "acct_1Test Court", dry_run: false)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("success" => false, "message" => "stripe_account_id must be a Stripe account id (acct_...)")
      expect(Comment.count).to eq(0)
    end

    it "returns 422 for a firm email carrying an extra header" do
      post :create, params: notice_params.merge(firm_email: "notices@example.com\nBcc: x@example.com", dry_run: false)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(0)
    end

    it "returns 404 for an account id no seller uses" do
      post :create, params: notice_params.merge(stripe_account_id: "acct_1TestUnknown0004")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to be(false)
    end

    it "returns 409 for an account id shared by two live sellers" do
      create(:merchant_account, user: create(:user)).update_columns(charge_processor_merchant_id: "acct_1TestCourtOrder04", deleted_at: 1.day.ago)

      post :create, params: notice_params.merge(dry_run: false)

      expect(response).to have_http_status(:conflict)
      expect(Comment.count).to eq(0)
    end
  end
end
