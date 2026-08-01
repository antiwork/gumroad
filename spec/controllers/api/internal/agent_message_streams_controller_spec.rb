# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"
require "shared_examples/explained_agent_rate_limit"

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

  def store_agent_turn(reply:, proposed_action:, objects: [])
    outcome =
      if proposed_action.present?
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

    # Stands in for the service: invokes on_reply_complete with the finished turn (the way
    # respond_streaming does the moment the reply is final) and returns the full result.
    def stub_streaming_service(**attributes)
      turn = store_agent_turn(**attributes)
      service_double = instance_double(Ai::StoreAgentService)
      allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:respond_streaming) do |messages:, on_reply_complete: nil, &_blk|
        on_reply_complete&.call(turn)
        turn.merge(suggestions: [])
      end
      service_double
    end

    context "when authenticated and authorized" do
      it "commits the stream with a keepalive comment before any event" do
        # ActionController::Live holds response headers until the first write, and a turn that
        # opens with silent tool work can go minutes before its first real event — the client
        # can't start its stall detection until it sees the response begin. The comment must be
        # the very first thing on the stream.
        stub_streaming_service(reply: "Hi.", proposed_action: nil, objects: [])

        post :create, params: valid_params, format: :json

        expect(response.body).to start_with(": connected\n\n")
      end

      it "writes keepalive heartbeats while the turn generates without emitting events" do
        # Tool-use iterations write nothing to the stream, so without heartbeats a healthy
        # multi-tool turn looks identical to a dead connection from the client's side.
        stub_const("Api::Internal::AgentMessageStreamsController::STREAM_HEARTBEAT_INTERVAL", 0.02.seconds)
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond_streaming) do |messages:, on_reply_complete: nil, &_blk|
          sleep 0.15
          turn = store_agent_turn(reply: "Done.", proposed_action: nil)
          on_reply_complete&.call(turn)
          turn.merge(suggestions: [])
        end

        post :create, params: valid_params, format: :json

        expect(response.body).to include(": heartbeat\n\n")
        expect(response.body).to include("event: done")
      end

      it "persists the turn to a new conversation and emits its id on the done event" do
        stub_streaming_service(reply: "You have 3 products.", proposed_action: nil, objects: [])

        post :create, params: valid_params, format: :json

        conversation = seller.ai_conversations.sole
        expect(conversation.title).to eq("How are my sales?")
        expect(conversation.ai_messages.map { |m| [m.role, m.content] }).to eq(
          [["user", "How are my sales?"], ["assistant", "You have 3 products."]]
        )
        expect(response.body).to include("event: done")
        expect(response.body).to include(conversation.external_id)
      end

      it "emits the persisted proposal message id on the done event" do
        stub_streaming_service(
          reply: "Confirm this discount.",
          proposed_action: { "type" => "api_write", "params" => { "endpoint" => "create_offer_code" } },
          objects: [],
        )

        post :create, params: valid_params, format: :json

        message = seller.ai_conversations.sole.ai_messages.role_assistant.sole
        done_data = JSON.parse(response.body[/event: done\ndata: (.*)\n/, 1])
        expect(done_data["proposal_message_id"]).to eq(message.external_id)
        expect(done_data).not_to have_key("outcome")
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
          ],
          on_reply_complete: kind_of(Proc),
        ) do |on_reply_complete:, **|
          turn = store_agent_turn(reply: "Up.", proposed_action: nil)
          on_reply_complete.call(turn)
          turn.merge(suggestions: [])
        end

        expect do
          post :create, params: valid_params.merge(conversation_id: conversation.external_id), format: :json
        end.not_to change { seller.ai_conversations.count }

        expect(conversation.ai_messages.reload.count).to eq(3)
      end

      # The streaming path must build history the same way as the buffered one: an applied proposal
      # turn reaches the model as server-owned state, never as its old "confirm that card" copy.
      it "replays an applied proposal turn as server-owned state" do
        conversation = create(:ai_conversation, seller:)
        create(:ai_message, ai_conversation: conversation, content: "Upload the portrait")
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Confirm that card and the upload goes through.",
          metadata: {
            "proposed_action" => { "type" => "api_write", "params" => { "endpoint" => "update_user_custom_html" } },
            "action_status" => "applied",
            "client_turn_id" => "8f14e45f",
          },
        )

        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        expect(service_double).to receive(:respond_streaming).with(
          messages: [
            { role: "user", content: "Upload the portrait" },
            {
              role: "assistant",
              content: "You proposed a change on this turn.",
              proposal_state: "the action was applied and cannot be confirmed again",
            },
            { role: "user", content: "How are my sales?" },
          ],
          on_reply_complete: kind_of(Proc),
        ) do |on_reply_complete:, **|
          turn = store_agent_turn(reply: "Already applied.", proposed_action: nil)
          on_reply_complete.call(turn)
          turn.merge(suggestions: [])
        end

        post :create, params: valid_params.merge(conversation_id: conversation.external_id), format: :json

        expect(response).to have_http_status(:ok)
      end

      it "still emits the done event but suppresses an unpersisted proposal" do
        proposal = { "type" => "api_write", "params" => { "endpoint" => "create_offer_code" } }
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond_streaming) do |on_reply_complete: nil, **_kwargs, &emit|
          turn = store_agent_turn(reply: "Confirm this discount.", proposed_action: proposal)
          on_reply_complete&.call(turn)
          emit.call(:token, { text: turn[:reply] })
          emit.call(:objects, { objects: [{ type: "product", title: "Course" }] })
          emit.call(:proposed_action, { proposed_action: proposal })
          emit.call(:suggestions, { suggestions: ["Show my products"] })
          turn.merge(suggestions: ["Show my products"])
        end
        allow(controller).to receive(:create_agent_conversation!).and_raise(ActiveRecord::StatementInvalid)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))
        client_turn_id = SecureRandom.uuid
        turn_status_key = RedisKey.agent_turn_status(seller.id, client_turn_id)

        post :create, params: valid_params.merge(client_turn_id:), format: :json

        expect(response.body).to include("event: done")
        expect(response.body).to include("there is nothing to confirm")
        expect(response.body).not_to include("event: error")
        expect(response.body).not_to include("Confirm this discount.")
        expect(response.body).to include("event: objects")
        expect(response.body).not_to include("event: suggestions")
        expect(response.body).not_to include("event: proposed_action")
        expect(response.body.scan(/^event: (.+)$/).flatten).to eq(
          %w[token objects done],
        )
        # The key must be omitted (not serialized as null) so the frame stays valid against the
        # client schema, where conversation_id is an optional string.
        done_data = JSON.parse(response.body[/event: done\ndata: (.*)\n/, 1])
        expect(done_data["reply"]).to eq(
          "I couldn't save that proposed change, so there is nothing to confirm. Please ask me to prepare it again.",
        )
        expect(done_data).not_to have_key("conversation_id")
        expect(done_data["proposed_action"]).to be_nil
        expect(done_data["suggestions"]).to eq([])
        expect(done_data).not_to have_key("proposal_message_id")
        expect(done_data).not_to have_key("outcome")
        expect($redis.get(turn_status_key)).to eq("failed")
      ensure
        $redis.del(turn_status_key) if turn_status_key
      end

      it "rejects and replaces server-owned confirmation copy without a proposal" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond_streaming) do |on_reply_complete: nil, **_kwargs, &emit|
          turn = store_agent_turn(reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY, proposed_action: nil)
          on_reply_complete&.call(turn)
          emit.call(:token, { text: turn[:reply] })
          turn.merge(suggestions: [])
        end
        expect(ErrorNotifier).to receive(:notify).with(
          an_instance_of(ArgumentError).and(having_attributes(
            message: "Store agent proposal reply requires a proposed action.",
          )),
        )

        expect do
          post :create, params: valid_params, format: :json
        end.to not_change { seller.ai_conversations.count }.and not_change { AiMessage.count }

        done_data = JSON.parse(response.body[/event: done\ndata: (.*)\n/, 1])
        expect(response.body).to include("event: token")
        expect(response.body).not_to include(Ai::StoreAgentService::PROPOSAL_READY_REPLY)
        expect(done_data["reply"]).to eq(Ai::StoreAgentService::NOTHING_STAGED_REPLY)
        expect(done_data["proposed_action"]).to be_nil
      end

      it "persists the turn before any trailing write, so a client disconnect can't drop it" do
        # The reply is final when on_reply_complete fires; every socket write after it can raise
        # ClientDisconnected (the seller's connection died mid-stream while the server kept
        # generating). The fully generated reply must already be stored by then — losing it would
        # mean the seller watched a reply stream in that no record of survives.
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond_streaming) do |messages:, on_reply_complete: nil, &_blk|
          on_reply_complete&.call(store_agent_turn(reply: "You have 3 products.", proposed_action: nil))
          raise ActionController::Live::ClientDisconnected
        end

        post :create, params: valid_params, format: :json

        conversation = seller.ai_conversations.sole
        expect(conversation.ai_messages.map { |m| [m.role, m.content] }).to eq(
          [["user", "How are my sales?"], ["assistant", "You have 3 products."]]
        )
      end

      context "with a client turn id" do
        let(:client_turn_id) { SecureRandom.uuid }
        let(:turn_status_key) { RedisKey.agent_turn_status(seller.id, client_turn_id) }

        after { $redis.del(turn_status_key) }

        it "stores the id on the persisted assistant message so the turn is recoverable by id" do
          stub_streaming_service(reply: "You have 3 products.", proposed_action: nil, objects: [])

          post :create, params: valid_params.merge(client_turn_id:), format: :json

          message = seller.ai_conversations.sole.ai_messages.role_assistant.sole
          expect(message.metadata["client_turn_id"]).to eq(client_turn_id)
        end

        it "keeps the in-progress marker armed while streaming so a broken client keeps waiting" do
          service_double = instance_double(Ai::StoreAgentService)
          allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
          allow(service_double).to receive(:respond_streaming) do |messages:, on_reply_complete: nil, &emit|
            # Mid-generation, before the turn persists, the marker must already read in_progress.
            expect($redis.get(turn_status_key)).to eq("in_progress")
            emit.call(:token, { text: "You " })
            turn = store_agent_turn(reply: "You have 3 products.", proposed_action: nil)
            on_reply_complete&.call(turn)
            turn.merge(suggestions: [])
          end

          post :create, params: valid_params.merge(client_turn_id:), format: :json
        end

        it "records a failed marker when persistence fails, so a recovering client stops waiting" do
          stub_streaming_service(reply: "You have 3 products.", proposed_action: nil, objects: [])
          allow(controller).to receive(:create_agent_conversation!).and_raise(ActiveRecord::StatementInvalid)
          allow(ErrorNotifier).to receive(:notify)

          post :create, params: valid_params.merge(client_turn_id:), format: :json

          expect($redis.get(turn_status_key)).to eq("failed")
        end

        it "records a failed marker when the service errors before the turn persists" do
          service_double = instance_double(Ai::StoreAgentService)
          allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
          allow(service_double).to receive(:respond_streaming).and_raise(Ai::StoreAgentService::Error, "nope")

          post :create, params: valid_params.merge(client_turn_id:), format: :json

          expect($redis.get(turn_status_key)).to eq("failed")
          expect(response.body).to include("event: error")
        end

        it "leaves the persisted turn (not a failed marker) when the client disconnects after persistence" do
          service_double = instance_double(Ai::StoreAgentService)
          allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
          allow(service_double).to receive(:respond_streaming) do |messages:, on_reply_complete: nil, &_blk|
            on_reply_complete&.call(store_agent_turn(reply: "You have 3 products.", proposed_action: nil))
            raise ActionController::Live::ClientDisconnected
          end

          post :create, params: valid_params.merge(client_turn_id:), format: :json

          expect($redis.get(turn_status_key)).not_to eq("failed")
          message = seller.ai_conversations.sole.ai_messages.role_assistant.sole
          expect(message.metadata["client_turn_id"]).to eq(client_turn_id)
        end

        it "ignores a malformed client turn id rather than erroring" do
          stub_streaming_service(reply: "You have 3 products.", proposed_action: nil, objects: [])

          post :create, params: valid_params.merge(client_turn_id: "not/a?valid*id"), format: :json

          expect(response.body).to include("event: done")
          message = seller.ai_conversations.sole.ai_messages.role_assistant.sole
          expect(message.metadata).to be_nil
        end
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

      it_behaves_like "an explained agent rate limit" do
        subject do
          exhaust_agent_request_throttle(throttle_key)
          post :create, params: valid_params, format: :json
        end
      end
    end
  end
end
