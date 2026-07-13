# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::AgentStreamsController do
  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api")
    @auth_params = { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: @token.token }
  end

  after { $redis.del(RedisKey.agent_request_throttle(@seller.id)) }

  def exhaust_agent_request_throttle(seller)
    $redis.setex(
      RedisKey.agent_request_throttle(seller.id),
      described_class.const_get(:AGENT_REQUESTS_PERIOD_WINDOW).to_i,
      described_class.const_get(:AGENT_REQUESTS_PER_PERIOD),
    )
  end

  describe "POST create" do
    let(:valid_params) { @auth_params.merge(messages: [{ role: "user", content: "How are my sales?" }]) }

    it "rejects a request with an invalid mobile token" do
      post :create, params: valid_params.merge(mobile_token: "invalid_token")

      expect(response.status).to be(401)
    end

    it "rejects a request with an invalid access token" do
      post :create, params: valid_params.merge(access_token: "invalid_token")

      expect(response.status).to be(401)
    end

    it "streams the turn's events and ends with a done event carrying the conversation id" do
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond_streaming) do |**_kwargs, &emit|
        emit.call(:token, { text: "You have " })
        emit.call(:token, { text: "3 products." })
        { reply: "You have 3 products.", proposed_action: nil, objects: [], suggestions: ["What sold this week?"] }
      end

      post :create, params: valid_params

      conversation = @seller.ai_conversations.sole
      expect(conversation.title).to eq("How are my sales?")
      expect(conversation.ai_messages.map { |m| [m.role, m.content] }).to eq(
        [["user", "How are my sales?"], ["assistant", "You have 3 products."]]
      )
      expect(response.headers["Content-Type"]).to include("text/event-stream")
      expect(response.body).to include("event: token")
      expect(response.body).to include("event: done")
      expect(response.body).to include(conversation.external_id)
    end

    it "replays the stored transcript when resuming a conversation" do
      conversation = create(:ai_conversation, seller: @seller)
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
        post :create, params: valid_params.merge(conversation_id: conversation.external_id)
      end.not_to change { @seller.ai_conversations.count }

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

      post :create, params: valid_params

      expect(response.body).to include("event: done")
      expect(response.body).to include("You have 3 products.")
      expect(response.body).not_to include("event: error")
    end

    it "emits an error event (not a new conversation) for another seller's conversation id" do
      other_conversation = create(:ai_conversation)

      expect(Ai::StoreAgentService).not_to receive(:new)

      expect do
        post :create, params: valid_params.merge(conversation_id: other_conversation.external_id)
      end.not_to change { AiConversation.count }

      expect(response.body).to include("event: error")
    end

    it "emits an error event and persists nothing when the service fails mid-stream" do
      # The response is already committed as an event stream by the time the service raises, so the
      # failure has to arrive as an `error` event (not an HTTP error status) and the stream must
      # still close cleanly. A failed turn also must not leave a stray user message behind — the
      # seller will retry, and a stored orphan would get silently replayed to the model.
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond_streaming) do |**_kwargs, &emit|
        emit.call(:token, { text: "Let me check" })
        raise Ai::StoreAgentService::Error, "The agent is unavailable right now."
      end

      expect do
        post :create, params: valid_params
      end.not_to change { AiConversation.count }

      expect(response.body).to include("event: error")
      expect(response.body).to include("The agent is unavailable right now.")
      expect(response.body).not_to include("event: done")
      expect(response.stream).to be_closed
    end

    it "emits an error event when no user message is provided" do
      expect(Ai::StoreAgentService).not_to receive(:new)

      post :create, params: @auth_params.merge(messages: [])

      expect(response.body).to include("event: error")
      expect(response.body).to include("A message is required.")
    end

    it "halts on throttle without invoking the streaming agent service" do
      exhaust_agent_request_throttle(@seller)
      expect(Ai::StoreAgentService).not_to receive(:new)

      post :create, params: valid_params

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to be_present
    end

    it "returns a forbidden error when the seller can't use the agent" do
      allow_any_instance_of(UserPolicy).to receive(:use_store_agent?).and_return(false)
      expect(Ai::StoreAgentService).not_to receive(:new)

      post :create, params: valid_params

      expect(response).to have_http_status(:forbidden)
    end
  end
end
