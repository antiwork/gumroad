# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::AgentController do
  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api")
    @auth_params = { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: @token.token }
  end

  describe "GET meta" do
    it "returns the greeting and starter suggestions" do
      get :meta, params: @auth_params

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["success"]).to be(true)
      expect(body["enabled"]).to be(true)
      expect(body["greeting"]).to eq(AgentPresenter::GREETING)
      expect(body["suggestions"]).to eq(AgentPresenter::SUGGESTIONS)
    end

    it "rejects a request with an invalid mobile token" do
      get :meta, params: @auth_params.merge(mobile_token: "invalid_token")

      expect(response.status).to be(401)
    end

    it "rejects a request with an invalid access token" do
      get :meta, params: @auth_params.merge(access_token: "invalid_token")

      expect(response.status).to be(401)
    end
  end

  describe "POST create" do
    let(:valid_params) { @auth_params.merge(messages: [{ role: "user", content: "How are my sales?" }]) }

    it "returns the agent's reply and any proposed action" do
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond).and_return(reply: "You have 3 products.", proposed_action: nil)

      post :create, params: valid_params

      expect(response).to be_successful
      expect(response.parsed_body).to eq(
        "success" => true,
        "reply" => "You have 3 products.",
        "proposed_action" => nil,
        "objects" => [],
      )
    end

    it "scopes the agent service to the authenticated seller" do
      expect(Ai::StoreAgentService).to receive(:new) do |args|
        expect(args[:seller]).to eq(@seller)
        expect(args[:pundit_user].seller).to eq(@seller)
        instance_double(Ai::StoreAgentService, respond: { reply: "ok", proposed_action: nil })
      end

      post :create, params: valid_params

      expect(response).to be_successful
    end

    it "rejects an empty message list" do
      post :create, params: @auth_params.merge(messages: [])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["success"]).to be(false)
    end

    it "surfaces a service error as unprocessable" do
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond).and_raise(Ai::StoreAgentService::Error.new("The assistant is unavailable."))

      post :create, params: valid_params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("success" => false, "error" => "The assistant is unavailable.")
    end
  end

  describe "POST execute" do
    let(:valid_params) { @auth_params.merge(type: "api_write", params: { endpoint: "create_discount", code: "LAUNCH", percent_off: 20 }) }

    it "executes a confirmed action and returns the result" do
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount LAUNCH.")

      post :execute, params: valid_params

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true, "message" => "Created discount LAUNCH.")
    end

    it "passes the confirmed action through to the executor" do
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      expect(executor_double).to receive(:execute).with(
        type: "api_write",
        params: { "endpoint" => "create_discount", "code" => "LAUNCH", "percent_off" => "20" },
      ).and_return(success: true, message: "Created discount LAUNCH.")

      post :execute, params: valid_params

      expect(response).to be_successful
    end

    it "rejects an unsupported action type" do
      post :execute, params: @auth_params.merge(type: "delete_everything", params: {})

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["success"]).to be(false)
    end

    it "returns unprocessable when the executor reports failure" do
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      allow(executor_double).to receive(:execute).and_return(success: false, message: "That change couldn't be saved.")

      post :execute, params: valid_params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be(false)
    end
  end
end
