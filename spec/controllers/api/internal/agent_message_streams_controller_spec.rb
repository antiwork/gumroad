# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"

describe Api::Internal::AgentMessageStreamsController do
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
      it "persists the turn to a new conversation and emits its id on the done event" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond_streaming).and_return(
          reply: "You have 3 products.",
          proposed_action: nil,
          objects: [],
          suggestions: [],
        )

        post :create, params: valid_params, format: :json

        conversation = seller.ai_conversations.sole
        expect(conversation.title).to eq("How are my sales?")
        expect(conversation.ai_messages.map { |m| [m.role, m.content] }).to eq(
          [["user", "How are my sales?"], ["assistant", "You have 3 products."]]
        )
        expect(response.body).to include("event: done")
        expect(response.body).to include(conversation.external_id)
      end

      it "replays the stored transcript when resuming a conversation" do
        conversation = create(:ai_conversation, seller:)
        create(:ai_message, ai_conversation: conversation, content: "Earlier question")

        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        expect(service_double).to receive(:respond_streaming).with(
          messages: [
            { role: "user", content: "Earlier question" },
            { role: "user", content: "How are my sales?" },
          ]
        ).and_return(reply: "Up.", proposed_action: nil, objects: [], suggestions: [])

        expect do
          post :create, params: valid_params.merge(conversation_id: conversation.external_id), format: :json
        end.not_to change { seller.ai_conversations.count }

        expect(conversation.ai_messages.reload.count).to eq(3)
      end

      it "still emits the done event when persisting the turn fails after streaming" do
        # The seller has already watched the reply stream in by the time persistence runs, so a DB
        # failure here must not turn the turn into an error — the done event (and the reply it
        # carries) still has to arrive. The conversation id is simply omitted.
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond_streaming).and_return(
          reply: "You have 3 products.",
          proposed_action: nil,
          objects: [],
          suggestions: [],
        )
        allow(controller).to receive(:create_agent_conversation!).and_raise(ActiveRecord::StatementInvalid)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))

        post :create, params: valid_params, format: :json

        expect(response.body).to include("event: done")
        expect(response.body).to include("You have 3 products.")
        expect(response.body).not_to include("event: error")
      end

      it "emits an error event (not a new conversation) for another seller's conversation id" do
        other_conversation = create(:ai_conversation)

        expect(Ai::StoreAgentService).not_to receive(:new)

        expect do
          post :create, params: valid_params.merge(conversation_id: other_conversation.external_id), format: :json
        end.not_to change { AiConversation.count }

        expect(response.body).to include("event: error")
      end

      it "halts on throttle without invoking the streaming agent service" do
        exhaust_agent_request_throttle(throttle_key)
        expect(Ai::StoreAgentService).not_to receive(:new)

        post :create, params: valid_params, format: :json

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to be_present
      end
    end
  end
end
