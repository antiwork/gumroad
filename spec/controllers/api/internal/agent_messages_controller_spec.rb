# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"

describe Api::Internal::AgentMessagesController do
  let(:seller) { create(:named_seller) }
  let(:throttle_key) { RedisKey.agent_request_throttle(seller.id) }

  include_context "with user signed in as admin for seller"

  after { $redis.del(throttle_key) }

  def exhaust_agent_request_throttle(key)
    $redis.setex(
      key,
      described_class.const_get(:AGENT_REQUESTS_PERIOD_WINDOW).to_i,
      described_class.const_get(:AGENT_REQUESTS_PER_PERIOD),
    )
  end

  describe "POST create" do
    let(:valid_params) { { messages: [{ role: "user", content: "How are my sales?" }] } }

    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { valid_params }
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { seller }
      let(:policy_method) { :use_store_agent? }
      let(:request_params) { valid_params }
      let(:request_format) { :json }
    end

    context "when authenticated and authorized" do
      it "returns the agent's reply and any proposed action" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond).and_return(
          reply: "You have 3 products.",
          proposed_action: nil,
        )

        post :create, params: valid_params, format: :json

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true, "reply" => "You have 3 products.", "proposed_action" => nil, "objects" => [])
      end

      it "rejects an empty message list" do
        post :create, params: { messages: [] }, format: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["success"]).to be(false)
      end

      it "halts on throttle without invoking the agent service" do
        exhaust_agent_request_throttle(throttle_key)
        expect(Ai::StoreAgentService).not_to receive(:new)

        post :create, params: valid_params, format: :json

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to be_present
      end
    end
  end

  describe "POST execute" do
    let(:valid_params) { { type: "api_write", params: { endpoint: "create_discount", code: "LAUNCH", percent_off: 20 } } }

    it_behaves_like "authentication required for action", :post, :execute do
      let(:request_params) { valid_params }
    end

    it_behaves_like "authorize called for action", :post, :execute do
      let(:record) { seller }
      let(:policy_method) { :use_store_agent? }
      let(:request_params) { valid_params }
      let(:request_format) { :json }
    end

    context "when authenticated and authorized" do
      it "applies a confirmed action via the executor" do
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount code LAUNCH.")

        post :execute, params: valid_params, format: :json

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true, "message" => "Created discount code LAUNCH.")
      end

      it "rejects an unsupported action type" do
        post :execute, params: { type: "delete_account", params: {} }, format: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["success"]).to be(false)
      end

      it "returns 422 when the executor reports failure" do
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: false, message: "That discount couldn't be created.")

        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["success"]).to be(false)
      end

      it "halts on throttle without invoking the action executor" do
        exhaust_agent_request_throttle(throttle_key)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to be_present
      end
    end
  end
end
