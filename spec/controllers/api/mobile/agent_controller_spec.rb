# frozen_string_literal: true

require "spec_helper"
require "shared_examples/explained_agent_rate_limit"

describe Api::Mobile::AgentController do
  let(:execution_abandoned_after) do
    AgentConversationPersistence.const_get(:ACTION_EXECUTION_ABANDONED_AFTER, false)
  end
  let(:database_now) { AiMessage.connection.select_value("SELECT CURRENT_TIMESTAMP(6)") }

  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api")
    @auth_params = { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: @token.token }
  end

  before do
    allow_any_instance_of(User).to receive(:eligible_for_store_agent?).and_return(true)
  end

  after { $redis.del(RedisKey.agent_request_throttle(@seller.id)) }

  def exhaust_agent_request_throttle(seller)
    $redis.setex(
      RedisKey.agent_request_throttle(seller.id),
      described_class.const_get(:AGENT_REQUESTS_PERIOD_WINDOW).to_i,
      described_class.const_get(:AGENT_REQUESTS_PER_PERIOD),
    )
  end

  def store_agent_turn(reply:, proposed_action: nil, objects: [])
    outcome =
      if proposed_action
        Ai::StoreAgentService::TURN_OUTCOME_PROPOSAL_READY
      else
        Ai::StoreAgentService::TURN_OUTCOME_REPLY_ONLY
      end

    {
      outcome:,
      reply:,
      proposed_action:,
      objects:,
    }
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
      allow(service_double).to receive(:respond).and_return(store_agent_turn(reply: "You have 3 products."))

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

    it "returns the persisted proposal message id" do
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond).and_return(store_agent_turn(
        reply: "Confirm this discount.",
        proposed_action: { "type" => "api_write", "params" => { "endpoint" => "create_discount" } },
      ))

      post :create, params: valid_params

      message = @seller.ai_conversations.sole.ai_messages.role_assistant.sole
      expect(response.parsed_body["proposal_message_id"]).to eq(message.external_id)
      expect(response.parsed_body).not_to have_key("outcome")
    end

    it "scopes the agent service to the authenticated seller" do
      expect(Ai::StoreAgentService).to receive(:new) do |args|
        expect(args[:seller]).to eq(@seller)
        expect(args[:pundit_user].seller).to eq(@seller)
        instance_double(Ai::StoreAgentService, respond: store_agent_turn(reply: "ok"))
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

    it "replaces an unpersisted proposal with an honest non-confirmable reply" do
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond).and_return(store_agent_turn(
        reply: "Confirm this discount.",
        proposed_action: { "type" => "api_write", "params" => { "endpoint" => "create_discount" } },
      ))

      allow(controller).to receive(:record_agent_assistant_message!).and_raise(ActiveRecord::StatementInvalid)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))

      post :create, params: valid_params

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["reply"]).to eq(
        "I couldn't save that proposed change, so there is nothing to confirm. Please ask me to prepare it again.",
      )
      expect(response.parsed_body["proposed_action"]).to be_nil
      expect(response.parsed_body).not_to have_key("proposal_message_id")
    end

    it "rolls back both messages when the outcome does not match the proposed action" do
      proposal = { "type" => "api_write", "params" => { "endpoint" => "create_discount" } }
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond).and_return(
        store_agent_turn(reply: "Confirm this discount.", proposed_action: proposal).merge(
          outcome: Ai::StoreAgentService::TURN_OUTCOME_REPLY_ONLY,
        ),
      )
      expect(ErrorNotifier).to receive(:notify).with(
        an_instance_of(ArgumentError).and(having_attributes(
          message: "Store agent turn outcome does not match its proposed action.",
        )),
      )

      expect do
        post :create, params: valid_params
      end.to not_change { @seller.ai_conversations.count }.and not_change { AiMessage.count }

      expect(response).to be_successful
      expect(response.parsed_body["reply"]).to eq(
        "I couldn't save that proposed change, so there is nothing to confirm. Please ask me to prepare it again.",
      )
      expect(response.parsed_body["proposed_action"]).to be_nil
      expect(response.parsed_body).not_to have_key("outcome")
    end

    it "still returns a non-proposal reply when persistence fails" do
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond).and_return(store_agent_turn(reply: "Sales are up."))
      allow(controller).to receive(:record_agent_assistant_message!).and_raise(ActiveRecord::StatementInvalid)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))

      post :create, params: valid_params

      expect(response).to be_successful
      expect(response.parsed_body["reply"]).to eq("Sales are up.")
    end

    it "halts on throttle without invoking the agent (429 stops the action)" do
      exhaust_agent_request_throttle(@seller)
      expect(Ai::StoreAgentService).not_to receive(:new)

      post :create, params: valid_params

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to be_present
    end

    it_behaves_like "an explained agent rate limit" do
      subject do
        exhaust_agent_request_throttle(@seller)
        post :create, params: valid_params
      end
    end
  end

  describe "POST execute" do
    let(:confirmed_action_params) { { endpoint: "create_discount", code: "LAUNCH", percent_off: 20 } }
    let(:conversation) { create(:ai_conversation, seller: @seller) }
    let(:proposal_message) do
      create(
        :ai_message,
        ai_conversation: conversation,
        role: "assistant",
        metadata: {
          "proposed_action" => {
            "type" => "api_write",
            "params" => confirmed_action_params,
          },
        },
      )
    end
    let(:valid_params) do
      @auth_params.merge(
        type: "api_write",
        params: confirmed_action_params,
        conversation_id: conversation.external_id,
        proposal_message_id: proposal_message.external_id,
      )
    end

    it "executes a confirmed action and returns the result" do
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount LAUNCH.")

      post :execute, params: valid_params

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true, "message" => "Created discount LAUNCH.")
    end

    it "passes the persisted confirmed action through to the executor" do
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      expect(executor_double).to receive(:execute).with(
        type: "api_write",
        params: { "endpoint" => "create_discount", "code" => "LAUNCH", "percent_off" => 20 },
      ).and_return(success: true, message: "Created discount LAUNCH.")

      post :execute, params: valid_params

      expect(response).to be_successful
    end

    it "rejects an unsupported action type" do
      post :execute, params: @auth_params.merge(type: "delete_everything", params: {})

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["success"]).to be(false)
    end

    it "returns unprocessable and keeps the claim when the nested API reports failure" do
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      allow(executor_double).to receive(:execute).and_return(
        success: false,
        message: "That change couldn't be saved.",
        failure_reason: "api_failure",
        failure_status: 422,
      )

      post :execute, params: valid_params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "message" => "That change couldn't be saved.",
        "action_status" => "unknown",
      )
      expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
    end

    it "returns the honest failure to an installed client when a post-dispatch outcome is unknown" do
      allow(ErrorNotifier).to receive(:notify)
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      allow(executor_double).to receive(:execute).and_return(
        success: false,
        message: "That change couldn't be saved.",
        failure_reason: "api_failure",
      )

      post :execute, params: valid_params.except(:proposal_message_id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "message" => "That change couldn't be saved.",
        "action_status" => "unknown",
      )
      expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
    end

    it "accepts a deployed client without persisted ids when its payload has one recent pending match" do
      allow(ErrorNotifier).to receive(:notify)
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount LAUNCH.")

      post :execute, params: valid_params.except(:conversation_id, :proposal_message_id)

      expect(response).to be_successful
      expect(proposal_message.reload.metadata["action_status"]).to eq("applied")
    end

    it "rejects a tampered confirmed action before dispatch" do
      expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

      post :execute, params: valid_params.deep_merge(params: { percent_off: 100 })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to include("doesn't match")
      expect(response.parsed_body).not_to have_key("retryable")
    end

    it "rejects a replay before dispatch" do
      proposal_message.update!(metadata: proposal_message.metadata.merge("action_status" => "applied"))
      expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

      post :execute, params: valid_params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["message"]).to eq("That proposal has already been confirmed.")
      expect(response.parsed_body["action_status"]).to eq("applied")
    end

    it "settles a stale exact-id retry as unknown without dispatch" do
      proposal_message.update_columns(
        metadata: proposal_message.metadata.merge("action_status" => "executing"),
        updated_at: database_now - execution_abandoned_after - 1.second,
      )
      expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

      post :execute, params: valid_params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include(
        "message" => "That proposal has already been confirmed.",
        "action_status" => "unknown",
      )
      expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
    end

    it "returns the completed state when an installed client retries one completed proposal" do
      proposal_message.update!(metadata: proposal_message.metadata.merge("action_status" => "unknown"))
      allow(ErrorNotifier).to receive(:notify)
      expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

      post :execute, params: valid_params.except(:proposal_message_id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "message" => "That proposal has already been confirmed.",
        "action_status" => "unknown",
      )
    end

    it "returns the winning state when another confirmation applies during the claim race" do
      allow(controller).to receive(:compare_and_set_agent_action_claim) do
        proposal_message.update_column(:metadata, proposal_message.metadata.merge("action_status" => "applied"))
        0
      end
      expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

      post :execute, params: valid_params

      expect(controller).to have_received(:compare_and_set_agent_action_claim).once
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include(
        "message" => "That proposal has already been confirmed.",
        "action_status" => "applied",
      )
    end

    it "retries the claim when a concurrent pre-dispatch rejection safely releases it" do
      claim_attempts = 0
      allow(controller).to receive(:compare_and_set_agent_action_claim).and_wrap_original do |method, message|
        claim_attempts += 1
        if claim_attempts == 1
          message.update_column(:metadata, message.metadata.merge("action_status" => "executing"))
          expect(controller.send(:release_agent_action_claim!, message)).to be(true)
          0
        else
          method.call(message)
        end
      end
      executor_double = instance_double(Ai::StoreAgentActionExecutor)
      allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
      expect(executor_double).to receive(:execute).once.and_return(
        success: true,
        message: "Created discount LAUNCH.",
      )

      post :execute, params: valid_params

      expect(controller).to have_received(:compare_and_set_agent_action_claim).twice
      expect(response).to be_successful
      expect(proposal_message.reload.metadata["action_status"]).to eq("applied")
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
      proposal_message = create(
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
            "proposal_message_id" => proposal_message.external_id,
            "action_status" => "applied",
          },
        ],
      )
    end

    it "hides executing and unknown proposals from mobile releases that would make them confirmable again" do
      %w[executing unknown].each do |action_status|
        conversation = create(:ai_conversation, seller: @seller)
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Check your discount.",
          metadata: {
            "proposed_action" => { "type" => "api_write", "params" => { "code" => "LAUNCH" } },
            "action_status" => action_status,
          },
        )

        get :latest_conversation, params: @auth_params

        expect(response.parsed_body.dig("conversation", "messages")).to eq(
          [
            {
              "role" => "assistant",
              "content" => "The outcome of this change is not available in this app. Check your store before asking the agent to try again.",
            },
          ],
        )
      end
    end

    it "durably settles an abandoned execution before hiding it from mobile hydration" do
      conversation = create(:ai_conversation, seller: @seller)
      proposal_message = create(
        :ai_message,
        ai_conversation: conversation,
        role: "assistant",
        content: "Check your discount.",
        metadata: {
          "proposed_action" => { "type" => "api_write", "params" => { "code" => "LAUNCH" } },
          "action_status" => "executing",
        },
      )
      proposal_message.update_column(:updated_at, database_now - execution_abandoned_after - 1.second)
      conversation_activity_at = conversation.reload.updated_at

      get :latest_conversation, params: @auth_params

      expect(response.parsed_body.dig("conversation", "messages")).to eq(
        [
          {
            "role" => "assistant",
            "content" => "The outcome of this change is not available in this app. Check your store before asking the agent to try again.",
          },
        ],
      )
      expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
      expect(conversation.reload.updated_at).to eq(conversation_activity_at)
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

    it "hides executing and unknown proposals from recovered mobile turns" do
      %w[executing unknown].each do |action_status|
        recovered_turn_id = SecureRandom.uuid
        conversation = create(:ai_conversation, seller: @seller)
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Check your discount.",
          metadata: {
            "client_turn_id" => recovered_turn_id,
            "proposed_action" => { "type" => "api_write", "params" => { "code" => "LAUNCH" } },
            "action_status" => action_status,
          },
        )

        get :turn_status, params: @auth_params.merge(client_turn_id: recovered_turn_id)

        expect(response.parsed_body["message"]).to eq(
          "role" => "assistant",
          "content" => "The outcome of this change is not available in this app. Check your store before asking the agent to try again.",
        )
      end
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
      allow(service_double).to receive(:respond).and_return(store_agent_turn(reply:, proposed_action:))
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
            {
              role: "assistant",
              content: "Earlier answer",
              proposal_state: "no proposed action was recorded for this message",
            },
            { role: "user", content: "And this month?" },
          ],
        ).and_return(store_agent_turn(reply: "Better."))

        expect do
          post :create,
               params: @auth_params.merge(messages: [{ role: "user", content: "And this month?" }], conversation_id: conversation.external_id)
        end.not_to change { @seller.ai_conversations.count }

        expect(response.parsed_body["conversation_id"]).to eq(conversation.external_id)
        expect(conversation.ai_messages.reload.count).to eq(4)
      end

      # The buffered mobile endpoint shares the history builder, so a proposal turn must reach the
      # model as server-owned state here too.
      it "replays an applied proposal turn as server-owned state" do
        conversation = create(:ai_conversation, seller: @seller)
        create(:ai_message, ai_conversation: conversation, content: "Upload the portrait")
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Confirm that card and the upload goes through.",
          metadata: {
            "proposed_action" => { "type" => "api_write", "params" => { "endpoint" => "update_user_custom_html" } },
            "action_status" => "applied",
          },
        )

        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        expect(service_double).to receive(:respond).with(
          messages: [
            { role: "user", content: "Upload the portrait" },
            {
              role: "assistant",
              content: "You proposed a change on this turn.",
              proposal_state: "the action was applied and cannot be confirmed again",
            },
            { role: "user", content: "And this month?" },
          ],
        ).and_return(store_agent_turn(reply: "Already applied."))

        post :create, params: @auth_params.merge(messages: [{ role: "user", content: "And this month?" }], conversation_id: conversation.external_id)

        expect(response.parsed_body["conversation_id"]).to eq(conversation.external_id)
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
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::RecordInvalid))

        expect do
          post :create, params: valid_params
        end.to not_change { @seller.ai_conversations.count }.and not_change { AiMessage.count }

        # Persistence failure degrades to the generated reply instead of discarding it as a 500.
        expect(response).to be_successful
        expect(response.parsed_body["reply"]).to eq("You have 3 products.")
        expect(response.parsed_body["conversation_id"]).to be_nil
      end

      it "rejects and replaces server-owned confirmation copy without a proposal" do
        stub_agent_service(reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY)
        expect(ErrorNotifier).to receive(:notify).with(
          an_instance_of(ArgumentError).and(having_attributes(
            message: "Store agent proposal reply requires a proposed action.",
          )),
        )

        expect do
          post :create, params: valid_params
        end.to not_change { @seller.ai_conversations.count }.and not_change { AiMessage.count }

        expect(response).to be_successful
        expect(response.parsed_body["reply"]).to eq(Ai::StoreAgentService::NOTHING_STAGED_REPLY)
        expect(response.parsed_body["proposed_action"]).to be_nil
        expect(response.parsed_body["conversation_id"]).to be_nil
      end
    end

    describe "POST execute" do
      let(:confirmed_action_params) { { endpoint: "create_discount", code: "LAUNCH", percent_off: 20 } }
      let(:conversation) { create(:ai_conversation, seller: @seller) }
      let(:proposal) do
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Want me to create LAUNCH?",
          metadata: {
            "proposed_action" => {
              "type" => "api_write",
              "params" => confirmed_action_params,
            },
          },
        )
      end
      let(:valid_params) do
        @auth_params.merge(
          type: "api_write",
          params: confirmed_action_params,
          conversation_id: conversation.external_id,
          proposal_message_id: proposal.external_id,
        )
      end

      it "marks the exact stored proposal applied" do
        create(:ai_message, ai_conversation: conversation, content: "Create a discount")

        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount LAUNCH.")

        post :execute, params: valid_params

        expect(response).to be_successful
        expect(proposal.reload.metadata["action_status"]).to eq("applied")
      end

      it "matches an unchanged decimal after the client serializes it as an integer" do
        proposal.update!(
          metadata: proposal.metadata.deep_merge(
            "proposed_action" => { "params" => { "percent_off" => 20.0 } },
          ),
        )
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        expect(executor_double).to receive(:execute).once do |type:, params:|
          expect(type).to eq("api_write")
          expect(params["percent_off"]).to eql(20)
          { success: true, message: "Created discount LAUNCH." }
        end

        post :execute, params: valid_params

        expect(response).to be_successful
        expect(proposal.reload.metadata["action_status"]).to eq("applied")
      end

      it "matches an unchanged decimal sent as an ordinary form string" do
        proposal.update!(
          metadata: proposal.metadata.deep_merge(
            "proposed_action" => { "params" => { "percent_off" => 20.0 } },
          ),
        )
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        expect(executor_double).to receive(:execute).once do |type:, params:|
          expect(type).to eq("api_write")
          expect(params["percent_off"]).to eql(20)
          { success: true, message: "Created discount LAUNCH." }
        end

        post :execute, params: valid_params.deep_merge(params: { percent_off: "20" })

        expect(response).to be_successful
        expect(proposal.reload.metadata["action_status"]).to eq("applied")
      end

      it "rejects a numeric-looking string changed to an equivalent number before dispatch" do
        proposal.update!(
          metadata: proposal.metadata.deep_merge(
            "proposed_action" => { "params" => { "name" => "1e3" } },
          ),
        )
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.deep_merge(params: { name: "1000" })

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
        expect(proposal.reload.metadata["action_status"]).to be_nil
      end

      it "rejects scientific notation for a stored numeric before dispatch" do
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.deep_merge(params: { percent_off: "2e1" })

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
        expect(proposal.reload.metadata["action_status"]).to be_nil
      end

      it "keeps success but records an unknown outcome when finalizing the audit fails" do
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount LAUNCH.")
        allow(controller).to receive(:record_agent_action_applied!).and_raise(ActiveRecord::StatementInvalid)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))

        post :execute, params: valid_params

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true, "message" => "Created discount LAUNCH.")
        expect(proposal.reload.metadata["action_status"]).to eq("unknown")
      end

      it "releases the proposal claim when the executor rejects before dispatch" do
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(
          success: false,
          message: "That change couldn't be saved.",
          retry_safe: true,
        )

        post :execute, params: valid_params

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => "That change couldn't be saved.",
          "retryable" => true,
        )
        expect(proposal.reload.metadata["action_status"]).to be_nil
      end

      it "404s without executing when the conversation belongs to another seller" do
        other_conversation = create(:ai_conversation)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.merge(conversation_id: other_conversation.external_id)

        expect(response).to have_http_status(:not_found)
      end

      it "reports a RecordNotFound raised inside the executor as an indeterminate claim" do
        # A RecordNotFound from the executor (e.g. an internal dispatch calling find! on a product
        # that no longer exists) is an unexpected failure — it must be logged + notified and return
        # the retained-claim status, not reuse the 404 meant for a bad conversation_id.
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_raise(ActiveRecord::RecordNotFound)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::RecordNotFound))

        post :execute, params: valid_params

        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body).to include(
          "message" => "The action may have completed, so it can't be retried automatically.",
          "action_status" => "unknown",
        )
        expect(proposal.reload.metadata["action_status"]).to eq("unknown")
      end
    end
  end
end
