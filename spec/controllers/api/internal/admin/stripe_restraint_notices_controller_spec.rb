# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::StripeRestraintNoticesController do
  let(:admin_user) { create(:admin_user) }

  it "inherits from Api::Internal::Admin::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Admin::BaseController)
  end

  describe "POST create" do
    # The shared examples' before block also provisions the admin token + header for this block.
    include_examples "admin api authorization required", :post, :create, { stripe_account_id: "acct_1SA76bS5BbOI7YuG" }

    let(:seller) { create(:user, email: "restrained-seller@example.com") }
    let(:account_id) { "acct_1SA76bS5BbOI7YuG" }
    let(:notice_key) { "stripe-restraint:#{account_id}:cwallace@scalefirm.com:8f14e45f" }
    let(:notice_params) do
      {
        stripe_account_id: account_id,
        firm_name: "Scale LLP",
        firm_email: "cwallace@scalefirm.com",
        notice_key:,
      }
    end

    before do
      create(:merchant_account, user: seller, charge_processor_merchant_id: account_id)
      request.headers["Authorization"] = "Bearer #{AdminApiToken.mint!(actor_user_id: admin_user.id)}"
    end

    it "rejects the legacy shared admin token" do
      request.headers["Authorization"] = "Bearer test-admin-token"

      expect do
        post :create, params: notice_params.merge(dry_run: false)
      end.to_not change { seller.comments.count }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["message"]).to eq("per-actor admin token is required")
    end

    it "defaults to a dry run: returns the matched user and the email, and sends nothing" do
      post :create, params: notice_params

      expect(response).to have_http_status(:ok)
      expect(seller.comments.count).to eq(0)
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["dry_run"]).to be(true)
      expect(body["user_external_id"]).to eq(seller.external_id)
      expect(body["already_sent"]).to be(false)
      expect(body["rendered_email"]["body"]).to include("Scale LLP", "cwallace@scalefirm.com")
      # The call itself is still recorded: a dry run is an admin API call, not a read.
      expect(AdminApiAuditLog.last.action).to eq("stripe_restraint_notices.create")
    end

    it "does not queue the seller notice on a dry run" do
      expect do
        post :create, params: notice_params
      end.to_not have_enqueued_mail(MerchantRegistrationMailer, :stripe_restraint_notice)
    end

    it "notifies the seller when dry_run is false and audits the write" do
      expect do
        post :create, params: notice_params.merge(dry_run: false)
      end.to change { seller.comments.where(idempotency_key: notice_key).count }.by(1)
        .and change { AdminApiAuditLog.count }.by(1)
        .and have_enqueued_mail(MerchantRegistrationMailer, :stripe_restraint_notice)

      body = response.parsed_body
      expect(body["dry_run"]).to be(false)
      expect(body["already_sent"]).to be(false)
      expect(body["comment_id"]).to be_present

      audit_log = AdminApiAuditLog.last
      expect(audit_log.action).to eq("stripe_restraint_notices.create")
      expect(audit_log.target_external_id).to eq(seller.external_id)
      # The law firm's address is what the notice is about — the audit row must say who the seller
      # was pointed at.
      expect(audit_log.params_snapshot["firm_email"]).to eq("cwallace@scalefirm.com")
    end

    it "returns already_sent on a repeat call and does not notify again" do
      post :create, params: notice_params.merge(dry_run: false)

      expect do
        post :create, params: notice_params.merge(dry_run: false)
      end.to_not have_enqueued_mail(MerchantRegistrationMailer, :stripe_restraint_notice)

      expect(response.parsed_body["already_sent"]).to be(true)
      expect(seller.comments.where(idempotency_key: notice_key).count).to eq(1)
    end

    it "returns 404 when no live user owns the account" do
      post :create, params: notice_params.merge(stripe_account_id: "acct_unknown")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["success"]).to be(false)
    end

    it "returns 400 for a value that is not a Stripe account id" do
      post :create, params: notice_params.merge(stripe_account_id: "12345")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"]).to match(/acct_/)
    end

    it "returns 422 when the account maps to several live users" do
      other = create(:user, email: "other-owner@example.com")
      create(:merchant_account, user: other, charge_processor_merchant_id: "acct_other").update_column(:charge_processor_merchant_id, account_id)

      post :create, params: notice_params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to match(/live users/)
    end

    it "returns 409 when the notice key was already used with different content" do
      post :create, params: notice_params.merge(dry_run: false)
      post :create, params: notice_params.merge(firm_name: "Other LLP", dry_run: false)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["success"]).to be(false)
    end
  end
end
