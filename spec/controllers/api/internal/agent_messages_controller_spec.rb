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
        conversation = seller.ai_conversations.sole
        expect(response.parsed_body).to eq(
          "success" => true,
          "reply" => "You have 3 products.",
          "proposed_action" => nil,
          "objects" => [],
          "conversation_id" => conversation.external_id,
        )
      end

      it "creates a conversation titled from the first user message and persists both turns" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond).and_return(
          reply: "Sales are up.",
          proposed_action: { "type" => "api_write", "summary" => "Create a discount" },
        )

        expect do
          post :create, params: valid_params, format: :json
        end.to change { seller.ai_conversations.count }.by(1)

        conversation = seller.ai_conversations.sole
        expect(conversation.title).to eq("How are my sales?")
        expect(conversation.ai_messages.map { |m| [m.role, m.content] }).to eq(
          [["user", "How are my sales?"], ["assistant", "Sales are up."]]
        )
        # The proposal rides along in metadata so reloaded history re-renders its card.
        expect(conversation.ai_messages.last.metadata["proposed_action"]).to eq(
          "type" => "api_write", "summary" => "Create a discount"
        )
      end

      it "appends to an existing conversation and replays the server-held history to the service" do
        conversation = create(:ai_conversation, seller:)
        create(:ai_message, ai_conversation: conversation, content: "Earlier question")
        create(:ai_message, ai_conversation: conversation, role: "assistant", content: "Earlier answer")

        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        # The service must see the stored transcript plus the new turn — not whatever history the
        # client posted (here the client posted only the new message).
        expect(service_double).to receive(:respond).with(
          messages: [
            { role: "user", content: "Earlier question" },
            { role: "assistant", content: "Earlier answer" },
            { role: "user", content: "And this month?" },
          ]
        ).and_return(reply: "Also up.", proposed_action: nil)

        expect do
          post :create,
               params: { messages: [{ role: "user", content: "And this month?" }], conversation_id: conversation.external_id },
               format: :json
        end.not_to change { seller.ai_conversations.count }

        expect(response.parsed_body["conversation_id"]).to eq(conversation.external_id)
        expect(conversation.ai_messages.reload.count).to eq(4)
      end

      it "404s when the conversation belongs to another seller" do
        other_conversation = create(:ai_conversation)

        expect(Ai::StoreAgentService).not_to receive(:new)

        post :create, params: valid_params.merge(conversation_id: other_conversation.external_id), format: :json

        expect(response).to have_http_status(:not_found)
      end

      it "404s for a soft-deleted conversation" do
        conversation = create(:ai_conversation, seller:)
        conversation.mark_deleted!

        post :create, params: valid_params.merge(conversation_id: conversation.external_id), format: :json

        expect(response).to have_http_status(:not_found)
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

      it "marks the stored proposal applied when a conversation id is sent" do
        conversation = create(:ai_conversation, seller:)
        create(:ai_message, ai_conversation: conversation, content: "Create a discount")
        proposal_message = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "I can create that discount.",
          metadata: { "proposed_action" => { "type" => "api_write", "summary" => "Create discount LAUNCH" } },
        )

        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(
          success: true,
          message: "Created discount code LAUNCH.",
          object: { "type" => "discount", "title" => "LAUNCH", "fields" => [] },
        )

        post :execute, params: valid_params.merge(conversation_id: conversation.external_id), format: :json

        expect(response).to be_successful
        metadata = proposal_message.reload.metadata
        expect(metadata["action_status"]).to eq("applied")
        # The created object replaces the turn's lookup objects, matching what the live UI shows.
        expect(metadata["objects"]).to eq([{ "type" => "discount", "title" => "LAUNCH", "fields" => [] }])
      end

      it "does not touch stored history when the executor fails" do
        conversation = create(:ai_conversation, seller:)
        proposal_message = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          metadata: { "proposed_action" => { "type" => "api_write" } },
        )

        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: false, message: "Nope.")

        post :execute, params: valid_params.merge(conversation_id: conversation.external_id), format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "404s without executing when the conversation belongs to another seller" do
        other_conversation = create(:ai_conversation)

        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.merge(conversation_id: other_conversation.external_id), format: :json

        expect(response).to have_http_status(:not_found)
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
