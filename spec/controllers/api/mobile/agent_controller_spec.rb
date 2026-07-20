# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::AgentController do
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
        "conversation_id" => @seller.ai_conversations.sole.external_id,
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

    it "halts on throttle without invoking the agent (429 stops the action)" do
      exhaust_agent_request_throttle(@seller)
      expect(Ai::StoreAgentService).not_to receive(:new)

      post :create, params: valid_params

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to be_present
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

    it "halts on throttle without invoking the action executor" do
      exhaust_agent_request_throttle(@seller)
      expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

      post :execute, params: valid_params

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to be_present
    end
  end

  describe "GET latest_conversation" do
    it "returns null when the seller has no stored conversations" do
      get :latest_conversation, params: @auth_params

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true, "conversation" => nil)
    end

    it "returns the most recently active conversation with the full transcript" do
      older = create(:ai_conversation, seller: @seller, title: "Older chat")
      create(:ai_message, ai_conversation: older, content: "Old question")
      newer = create(:ai_conversation, seller: @seller, title: "Newer chat")
      create(:ai_message, ai_conversation: newer, content: "Create a discount")
      create(
        :ai_message,
        ai_conversation: newer,
        role: "assistant",
        content: "Here's a discount to confirm.",
        metadata: {
          "proposed_action" => { "type" => "api_write", "params" => { "code" => "LAUNCH" } },
          "action_status" => "applied",
        },
      )

      get :latest_conversation, params: @auth_params

      expect(response).to be_successful
      conversation = response.parsed_body["conversation"]
      expect(conversation["id"]).to eq(newer.external_id)
      expect(conversation["title"]).to eq("Newer chat")
      expect(conversation["messages"]).to eq(
        [
          { "role" => "user", "content" => "Create a discount" },
          {
            "role" => "assistant",
            "content" => "Here's a discount to confirm.",
            "proposed_action" => { "type" => "api_write", "params" => { "code" => "LAUNCH" } },
            "action_status" => "applied",
          },
        ],
      )
    end

    it "skips soft-deleted conversations and never returns another seller's" do
      deleted = create(:ai_conversation, seller: @seller)
      deleted.mark_deleted!
      create(:ai_conversation) # another seller's

      get :latest_conversation, params: @auth_params

      expect(response).to be_successful
      expect(response.parsed_body["conversation"]).to be_nil
    end
  end

  describe "GET turn_status" do
    let(:client_turn_id) { SecureRandom.uuid }

    after { $redis.del(RedisKey.agent_turn_status(@seller.id, client_turn_id)) }

    it "returns the persisted turn with its conversation id and message" do
      conversation = create(:ai_conversation, seller: @seller)
      create(
        :ai_message,
        ai_conversation: conversation,
        role: "assistant",
        content: "Your bio has three lines.",
        metadata: { "client_turn_id" => client_turn_id },
      )

      get :turn_status, params: @auth_params.merge(client_turn_id:)

      expect(response.parsed_body).to eq(
        "success" => true,
        "status" => "persisted",
        "conversation_id" => conversation.external_id,
        "message" => { "role" => "assistant", "content" => "Your bio has three lines." },
      )
    end

    it "reads the same liveness markers the streaming endpoint arms" do
      $redis.set(RedisKey.agent_turn_status(@seller.id, client_turn_id), "in_progress", ex: 60)

      get :turn_status, params: @auth_params.merge(client_turn_id:)

      expect(response.parsed_body).to eq("success" => true, "status" => "in_progress")
    end

    it "returns unknown when there is no stored turn and no marker" do
      get :turn_status, params: @auth_params.merge(client_turn_id:)

      expect(response.parsed_body).to eq("success" => true, "status" => "unknown")
    end

    it "never returns another seller's turn for the same id" do
      other_conversation = create(:ai_conversation) # different seller
      create(
        :ai_message,
        ai_conversation: other_conversation,
        role: "assistant",
        content: "Someone else's reply.",
        metadata: { "client_turn_id" => client_turn_id },
      )

      get :turn_status, params: @auth_params.merge(client_turn_id:)

      expect(response.parsed_body).to eq("success" => true, "status" => "unknown")
    end

    it "rejects a malformed turn id" do
      get :turn_status, params: @auth_params.merge(client_turn_id: "not-valid!*id")

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "conversation persistence" do
    def stub_agent_service(reply: "You have 3 products.", proposed_action: nil)
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond).and_return(reply:, proposed_action:)
      service_double
    end

    describe "POST create" do
      let(:valid_params) { @auth_params.merge(messages: [{ role: "user", content: "How are my sales?" }]) }

      it "creates a conversation titled from the first user message and returns its id" do
        stub_agent_service

        expect do
          post :create, params: valid_params
        end.to change { @seller.ai_conversations.count }.by(1)

        conversation = @seller.ai_conversations.sole
        expect(conversation.title).to eq("How are my sales?")
        expect(conversation.ai_messages.map { |m| [m.role, m.content] }).to eq(
          [["user", "How are my sales?"], ["assistant", "You have 3 products."]],
        )
        expect(response.parsed_body["conversation_id"]).to eq(conversation.external_id)
      end

      it "appends to an existing conversation and replays the server-held history to the service" do
        conversation = create(:ai_conversation, seller: @seller)
        create(:ai_message, ai_conversation: conversation, content: "Earlier question")
        create(:ai_message, ai_conversation: conversation, role: "assistant", content: "Earlier answer")

        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        expect(service_double).to receive(:respond).with(
          messages: [
            { role: "user", content: "Earlier question" },
            { role: "assistant", content: "Earlier answer" },
            { role: "user", content: "And this month?" },
          ],
        ).and_return(reply: "Better.", proposed_action: nil)

        expect do
          post :create,
               params: @auth_params.merge(messages: [{ role: "user", content: "And this month?" }], conversation_id: conversation.external_id)
        end.not_to change { @seller.ai_conversations.count }

        expect(response.parsed_body["conversation_id"]).to eq(conversation.external_id)
        expect(conversation.ai_messages.reload.count).to eq(4)
      end

      it "resumes a conversation started on the web (same store, no separate mobile silo)" do
        # A conversation created through the web controllers is just a row in ai_conversations;
        # the mobile endpoint appends to it exactly the same way.
        conversation = create(:ai_conversation, seller: @seller, title: "Started on web")
        create(:ai_message, ai_conversation: conversation, content: "Web question")
        stub_agent_service(reply: "Continuing on mobile.")

        post :create,
             params: @auth_params.merge(messages: [{ role: "user", content: "Mobile follow-up" }], conversation_id: conversation.external_id)

        expect(response).to be_successful
        expect(conversation.ai_messages.reload.map(&:content)).to include("Mobile follow-up", "Continuing on mobile.")
      end

      it "404s when the conversation belongs to another seller" do
        other_conversation = create(:ai_conversation)
        expect(Ai::StoreAgentService).not_to receive(:new)

        post :create, params: valid_params.merge(conversation_id: other_conversation.external_id)

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["success"]).to be(false)
      end

      it "404s for a soft-deleted conversation" do
        conversation = create(:ai_conversation, seller: @seller)
        conversation.mark_deleted!

        post :create, params: valid_params.merge(conversation_id: conversation.external_id)

        expect(response).to have_http_status(:not_found)
      end

      it "persists nothing when the service fails" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond).and_raise(Ai::StoreAgentService::Error.new("Unavailable."))

        expect do
          post :create, params: valid_params
        end.to not_change { @seller.ai_conversations.count }.and not_change { AiMessage.count }
      end

      it "rolls back the whole turn when the assistant write fails, leaving no stray user message" do
        stub_agent_service
        allow(controller).to receive(:record_agent_assistant_message!).and_raise(ActiveRecord::RecordInvalid)

        expect do
          post :create, params: valid_params
        end.to not_change { @seller.ai_conversations.count }.and not_change { AiMessage.count }

        expect(response).to have_http_status(:internal_server_error)
      end
    end

    describe "POST execute" do
      let(:valid_params) { @auth_params.merge(type: "api_write", params: { endpoint: "create_discount", code: "LAUNCH", percent_off: 20 }) }

      it "marks the stored proposal applied when a conversation id is sent" do
        conversation = create(:ai_conversation, seller: @seller)
        create(:ai_message, ai_conversation: conversation, content: "Create a discount")
        proposal = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Want me to create LAUNCH?",
          metadata: {
            "proposed_action" => {
              "type" => "api_write",
              "params" => { "endpoint" => "create_discount", "code" => "LAUNCH", "percent_off" => "20" },
            },
          },
        )

        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount LAUNCH.")

        post :execute, params: valid_params.merge(conversation_id: conversation.external_id)

        expect(response).to be_successful
        expect(proposal.reload.metadata["action_status"]).to eq("applied")
      end

      it "leaves the proposal untouched when the executor reports failure" do
        conversation = create(:ai_conversation, seller: @seller)
        proposal = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Want me to create LAUNCH?",
          metadata: {
            "proposed_action" => {
              "type" => "api_write",
              "params" => { "endpoint" => "create_discount", "code" => "LAUNCH", "percent_off" => "20" },
            },
          },
        )

        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: false, message: "That change couldn't be saved.")

        post :execute, params: valid_params.merge(conversation_id: conversation.external_id)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(proposal.reload.metadata["action_status"]).to be_nil
      end

      it "404s without executing when the conversation belongs to another seller" do
        other_conversation = create(:ai_conversation)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.merge(conversation_id: other_conversation.external_id)

        expect(response).to have_http_status(:not_found)
      end

      it "reports a RecordNotFound raised inside the executor as a 500, not a missing conversation" do
        # A RecordNotFound from the executor (e.g. an internal dispatch calling find! on a product
        # that no longer exists) is an unexpected failure — it must be logged + notified and return
        # a 500, not reuse the "conversation could not be found" 404 meant for a bad conversation_id.
        conversation = create(:ai_conversation, seller: @seller)
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_raise(ActiveRecord::RecordNotFound)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::RecordNotFound))

        post :execute, params: valid_params.merge(conversation_id: conversation.external_id)

        expect(response).to have_http_status(:internal_server_error)
        expect(response.parsed_body["message"]).to eq("Something went wrong. Please try again.")
      end
    end
  end
end
