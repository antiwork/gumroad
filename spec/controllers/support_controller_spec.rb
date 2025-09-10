# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe SupportController do
  let(:seller) { create(:named_seller) }


  describe "GET index" do
    context "when user is signed in" do
      before { sign_in seller }

      it "returns http success and assigns props with session" do
        allow(controller).to receive(:helper_widget_host).and_return("https://help.example.test")
        allow(controller).to receive(:helper_session).and_return({ "session_id" => "abc123" })

        get :index

        expect(response).to be_successful
        expect(assigns[:props]).to eq(
          host: "https://help.example.test",
          session: { "session_id" => "abc123" }
        )
      end
    end

    context "when user is not signed in" do
      it "redirects to help center" do
        get :index

        expect(response).to redirect_to(help_center_root_path)
      end
    end
  end

  describe "POST create_unauthenticated_ticket" do
    let(:valid_params) do
      {
        email: "test@example.com",
        subject: "Test subject",
        message: "Test message",
        "g-recaptcha-response" => "valid_recaptcha_token"
      }
    end

    before do
      allow(GlobalConfig).to receive(:get).with("RECAPTCHA_LOGIN_SITE_KEY").and_return("test_recaptcha_key")
      allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_HOST").and_return("https://helper.test")
      allow(GlobalConfig).to receive(:get).with("HELPER_WIDGET_SECRET").and_return("test_secret")
      allow(controller).to receive(:valid_recaptcha_response?).and_return(true)
    end

    context "with valid parameters and successful Helper API" do
      before do
        stub_request(:post, "https://helper.test/api/widget/session")
          .to_return(
            status: 200,
            body: { token: "mock_helper_token" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:post, "https://helper.test/api/chat/conversation")
          .to_return(
            status: 200,
            body: { conversationSlug: "test-conversation-123" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:post, "https://helper.test/api/chat/conversation/test-conversation-123/message")
          .to_return(
            status: 200,
            body: { success: true }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "creates a support ticket and returns success" do
        post :create_unauthenticated_ticket, params: valid_params

        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to eq({
                                             "success" => true,
                                             "conversation_slug" => "test-conversation-123"
                                           })

        expect(WebMock).to have_requested(:post, "https://helper.test/api/widget/session")
          .with(body: ->(body) {
            expect(JSON.parse(body)).to include(
              "email" => "test@example.com",
              "emailHash" => kind_of(String),
              "timestamp" => kind_of(Integer)
            )
          })

        expect(WebMock).to have_requested(:post, "https://helper.test/api/chat/conversation")
          .with(
            headers: { "Authorization" => "Bearer mock_helper_token" },
            body: ->(body) {
              expect(JSON.parse(body)).to include("subject" => "Test subject")
            }
          )

        expect(WebMock).to have_requested(:post, "https://helper.test/api/chat/conversation/test-conversation-123/message")
          .with(
            headers: { "Authorization" => "Bearer mock_helper_token" },
            body: ->(body) {
              expect(JSON.parse(body)).to include(
                "content" => "Test message",
                "customerInfoUrl" => end_with("/internal/helper/users/user_info")
              )
            }
          )
      end
    end

    context "with missing parameters" do
      it "returns bad request when email is missing" do
        params = valid_params.except(:email)

        post :create_unauthenticated_ticket, params: params

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({
                                             "error" => "Missing required parameters: email"
                                           })
      end

      it "returns bad request when subject is missing" do
        params = valid_params.except(:subject)

        post :create_unauthenticated_ticket, params: params

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({
                                             "error" => "Missing required parameters: subject"
                                           })
      end

      it "returns bad request when message is missing" do
        params = valid_params.except(:message)

        post :create_unauthenticated_ticket, params: params

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({
                                             "error" => "Missing required parameters: message"
                                           })
      end

      it "returns bad request when email is blank" do
        params = valid_params.merge(email: "")

        post :create_unauthenticated_ticket, params: params

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({
                                             "error" => "Missing required parameters: email"
                                           })
      end

      it "returns bad request when subject is blank" do
        params = valid_params.merge(subject: "")

        post :create_unauthenticated_ticket, params: params

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({
                                             "error" => "Missing required parameters: subject"
                                           })
      end

      it "returns bad request when message is blank" do
        params = valid_params.merge(message: "")

        post :create_unauthenticated_ticket, params: params

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to eq({
                                             "error" => "Missing required parameters: message"
                                           })
      end
    end

    context "with invalid reCAPTCHA" do
      before do
        allow(controller).to receive(:valid_recaptcha_response?).and_return(false)
      end

      it "returns unprocessable entity when recaptcha verification fails" do
        post :create_unauthenticated_ticket, params: valid_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({
                                             "error" => "reCAPTCHA verification failed"
                                           })
      end

      it "calls recaptcha validation with correct site key" do
        expect(controller).to receive(:valid_recaptcha_response?).with(
          site_key: "test_recaptcha_key"
        ).and_return(false)

        post :create_unauthenticated_ticket, params: valid_params
      end
    end
  end
end
