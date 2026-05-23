# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorized_helper_api_method"

class ApiInternalHelperSendgridEmailsControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::Helper::SendgridEmailsController
  tests Api::Internal::Helper::SendgridEmailsController



  context_ Api::Internal::Helper::SendgridEmailsController do
    let(:email) { "buyer@example.com" }
    let(:suppression_manager) { instance_double(EmailSuppressionManager) }

    before do
      request.headers["Authorization"] = "Bearer #{GlobalConfig.get("HELPER_TOOLS_TOKEN")}"
      allow(EmailSuppressionManager).to receive(:new).with(email).and_return(suppression_manager)
    end

  test "inherits from Api::Internal::Helper::BaseController" do
      expect(described_class.superclass).to eq(Api::Internal::Helper::BaseController)
    end

  context_ "POST check_status" do
      include_examples "helper api authorization required", :post, :check_status

  context_ "when email parameter is missing" do
  test "returns 400" do
          post :check_status
          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body).to eq("success" => false, "message" => "'email' parameter is required")
        end
      end

  context_ "when email is not suppressed" do
        before do
          allow(suppression_manager).to receive(:detailed_status).and_return(
            bounces: [], blocks: [], spam_reports: [], invalid_emails: []
          )
        end

  test "returns suppressed: false with empty SendGrid buckets" do
          post :check_status, params: { email: }

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

  context_ "when email is suppressed in some lists" do
        before do
          allow(suppression_manager).to receive(:detailed_status).and_return(
            bounces: [{ subuser: :gumroad, reason: "550 5.1.1 mailbox does not exist", created_at: "2025-01-15T00:00:00Z" }],
            blocks: [],
            spam_reports: [{ subuser: :creators, reason: "user marked as spam", created_at: "2025-01-15T00:00:00Z" }],
            invalid_emails: [],
          )
        end

  test "returns suppressed: true with details" do
          post :check_status, params: { email: }

          expect(response).to be_successful
          body = response.parsed_body
          expect(body["success"]).to eq(true)
          expect(body["suppressed"]).to eq(true)
          expect(body["sendgrid"]["bounces"].first["subuser"]).to eq("gumroad")
          expect(body["sendgrid"]["spam_reports"].first["subuser"]).to eq("creators")
        end
      end
    end

  context_ "POST remove_suppression" do
      include_examples "helper api authorization required", :post, :remove_suppression

  context_ "when email parameter is missing" do
  test "returns 400" do
          post :remove_suppression
          expect(response).to have_http_status(:bad_request)
        end
      end

  context_ "when list is invalid" do
  test "returns 400" do
          post :remove_suppression, params: { email:, list: "garbage" }

          expect(response).to have_http_status(:bad_request)
          expect(response.parsed_body["message"]).to include("Unsupported list(s): garbage")
        end
      end

  context_ "when list is omitted (defaults to all)" do
  test "removes from every supported list" do
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

  context_ "when list is a single value" do
  test "removes from only that list" do
          expect(suppression_manager).to receive(:remove_from_lists).with([:bounces]).and_return(bounces: [:gumroad])

          post :remove_suppression, params: { email:, list: "bounces" }

          expect(response).to be_successful
          expect(response.parsed_body["removed_from"]).to eq("bounces" => ["gumroad"])
        end
      end

  context_ "when list is 'all'" do
  test "removes from every supported list" do
          expected_lists = [:bounces, :blocks, :spam_reports, :invalid_emails]
          expect(suppression_manager).to receive(:remove_from_lists).with(expected_lists).and_return(
            bounces: [], blocks: [], spam_reports: [], invalid_emails: []
          )

          post :remove_suppression, params: { email:, list: "all" }

          expect(response).to be_successful
        end
      end
    end
  end
end
