# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_admin_api_method"

describe Api::Internal::Admin::SendgridEmailsController do
  let(:admin_user) { create(:admin_user) }
  let(:email) { "buyer@example.com" }
  let(:suppression_manager) { instance_double(EmailSuppressionManager) }

  before do
    allow(EmailSuppressionManager).to receive(:new).with(email).and_return(suppression_manager)
  end

  it "inherits from Api::Internal::Admin::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::Admin::BaseController)
  end

  describe "GET check_status" do
    include_examples "admin api authorization required", :get, :check_status

    context "when email parameter is missing" do
      it "returns 400" do
        get :check_status
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq("success" => false, "message" => "'email' parameter is required")
      end
    end

    context "when email is not suppressed" do
      before do
        allow(suppression_manager).to receive(:detailed_status).and_return(
          bounces: [], blocks: [], spam_reports: [], invalid_emails: []
        )
      end

      it "returns suppressed: false with empty SendGrid buckets" do
        get :check_status, params: { email: }

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to eq(true)
        expect(body["email"]).to eq(email)
        expect(body["suppressed"]).to eq(false)
        expect(body["sendgrid"]).to eq(
          "bounces" => [],
          "blocks" => [],
          "spam_reports" => [],
          "invalid_emails" => []
        )
      end
    end

    context "when email is suppressed in some lists" do
      before do
        allow(suppression_manager).to receive(:detailed_status).and_return(
          bounces: [{ subuser: :gumroad, reason: "550 5.1.1 mailbox does not exist", created_at: "2025-01-15T00:00:00Z" }],
          blocks: [],
          spam_reports: [{ subuser: :creators, reason: "user marked as spam", created_at: "2025-01-15T00:00:00Z" }],
          invalid_emails: [],
        )
      end

      it "returns suppressed: true with details" do
        get :check_status, params: { email: }

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to eq(true)
        expect(body["suppressed"]).to eq(true)
        expect(body["sendgrid"]["bounces"].first["subuser"]).to eq("gumroad")
        expect(body["sendgrid"]["spam_reports"].first["subuser"]).to eq("creators")
      end
    end
  end

  describe "POST remove_suppression" do
    include_examples "admin api authorization required", :post, :remove_suppression

    context "when email parameter is missing" do
      it "returns 400" do
        post :remove_suppression
        expect(response).to have_http_status(:bad_request)
      end
    end

    context "when list is invalid" do
      it "returns 400" do
        post :remove_suppression, params: { email:, list: "garbage" }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"]).to include("Unsupported list(s): garbage")
      end
    end

    context "when list is omitted (defaults to all)" do
      it "removes from every supported list" do
        expected_lists = [:bounces, :blocks, :spam_reports, :invalid_emails]
        expect(suppression_manager).to receive(:remove_from_lists).with(expected_lists).and_return(
          bounces: [:gumroad], blocks: [], spam_reports: [:creators], invalid_emails: []
        )

        post :remove_suppression, params: { email: }

        expect(response).to be_successful
        body = response.parsed_body
        expect(body["success"]).to eq(true)
        expect(body["removed_from"]).to eq(
          "bounces" => ["gumroad"],
          "blocks" => [],
          "spam_reports" => ["creators"],
          "invalid_emails" => []
        )
      end
    end

    context "when list is a single value" do
      it "removes from only that list" do
        expect(suppression_manager).to receive(:remove_from_lists).with([:bounces]).and_return(bounces: [:gumroad])

        post :remove_suppression, params: { email:, list: "bounces" }

        expect(response).to be_successful
        expect(response.parsed_body["removed_from"]).to eq("bounces" => ["gumroad"])
      end
    end

    context "when list is 'all'" do
      it "removes from every supported list" do
        expected_lists = [:bounces, :blocks, :spam_reports, :invalid_emails]
        expect(suppression_manager).to receive(:remove_from_lists).with(expected_lists).and_return(
          bounces: [], blocks: [], spam_reports: [], invalid_emails: []
        )

        post :remove_suppression, params: { email:, list: "all" }

        expect(response).to be_successful
      end
    end

    it "records an admin audit log" do
      allow(suppression_manager).to receive(:remove_from_lists).and_return(bounces: [])

      expect do
        post :remove_suppression, params: { email:, list: "bounces" }
      end.to change(AdminApiAuditLog, :count).by(1)

      audit_log = AdminApiAuditLog.last
      expect(audit_log.action).to eq("sendgrid_emails.remove_suppression")
      expect(audit_log.http_method).to eq("POST")
      # The email is the subject of this write, so it must survive redaction —
      # otherwise the audit row can't say which address was unsuppressed.
      expect(audit_log.params_snapshot["email"]).to eq(email)
      expect(audit_log.params_snapshot["list"]).to eq("bounces")
    end
  end
end
