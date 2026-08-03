# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"
require "shared_examples/explained_agent_rate_limit"

describe Api::Internal::AgentMessagesController do
  let(:seller) { create(:named_seller) }
  let(:throttle_key) { RedisKey.agent_request_throttle(seller.id) }
  let(:execution_abandoned_after) do
    AgentConversationPersistence.const_get(:ACTION_EXECUTION_ABANDONED_AFTER, false)
  end
  let(:database_now) { AiMessage.connection.select_value("SELECT CURRENT_TIMESTAMP(6)") }

  include_context "with user signed in as admin for seller"

  before do
    allow_any_instance_of(User).to receive(:eligible_for_store_agent?).and_return(true)
  end

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

    context "when authenticated and authorized" do
      it "returns the agent's reply and any proposed action" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond).and_return(store_agent_turn(
          reply: "You have 3 products.",
          proposed_action: nil,
        ))

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
        allow(service_double).to receive(:respond).and_return(store_agent_turn(
          reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY,
          proposed_action: { "type" => "api_write", "summary" => "Create a discount" },
        ))

        expect do
          post :create, params: valid_params, format: :json
        end.to change { seller.ai_conversations.count }.by(1)

        conversation = seller.ai_conversations.sole
        expect(conversation.title).to eq("How are my sales?")
        expect(conversation.ai_messages.map { |m| [m.role, m.content] }).to eq(
          [["user", "How are my sales?"], ["assistant", Ai::StoreAgentService::PROPOSAL_READY_REPLY]]
        )
        # The proposal rides along in metadata so reloaded history re-renders its card.
        expect(conversation.ai_messages.last.metadata["proposed_action"]).to eq(
          "type" => "api_write", "summary" => "Create a discount"
        )
        expect(response.parsed_body["proposal_message_id"]).to eq(conversation.ai_messages.last.external_id)
        expect(response.parsed_body).not_to have_key("outcome")
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
            {
              role: "assistant",
              content: "Earlier answer",
              proposal_state: "no proposed action was recorded for this message",
            },
            { role: "user", content: "And this month?" },
          ]
        ).and_return(store_agent_turn(reply: "Also up.", proposed_action: nil))

        expect do
          post :create,
               params: { messages: [{ role: "user", content: "And this month?" }], conversation_id: conversation.external_id },
               format: :json
        end.not_to change { seller.ai_conversations.count }

        expect(response.parsed_body["conversation_id"]).to eq(conversation.external_id)
        expect(conversation.ai_messages.reload.count).to eq(4)
      end

      it "replays only the most recent HISTORY_MAX_MESSAGES stored messages to the service" do
        stub_const("AgentConversationPersistence::HISTORY_MAX_MESSAGES", 2)
        conversation = create(:ai_conversation, seller:)
        create(:ai_message, ai_conversation: conversation, content: "Dropped question")
        create(:ai_message, ai_conversation: conversation, role: "assistant", content: "Dropped answer")
        create(:ai_message, ai_conversation: conversation, content: "Kept question")
        create(:ai_message, ai_conversation: conversation, role: "assistant", content: "Kept answer")

        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        # Only the newest window of the stored transcript (plus the new turn) reaches the model —
        # replaying the full history would make each turn's token cost grow without bound.
        expect(service_double).to receive(:respond).with(
          messages: [
            { role: "user", content: "Kept question" },
            {
              role: "assistant",
              content: "Kept answer",
              proposal_state: "no proposed action was recorded for this message",
            },
            { role: "user", content: "And this month?" },
          ]
        ).and_return(store_agent_turn(reply: "Capped.", proposed_action: nil))

        post :create,
             params: { messages: [{ role: "user", content: "And this month?" }], conversation_id: conversation.external_id },
             format: :json

        expect(response.parsed_body["success"]).to eq(true)
      end

      it "replays each assistant turn with its server-known proposal state" do
        conversation = create(:ai_conversation, seller:)
        proposal = { "type" => "api_write", "params" => { "endpoint" => "create_offer_code" } }
        [
          ["No proposal", nil],
          ["Pending proposal", { "proposed_action" => proposal }],
          ["Executing proposal", { "proposed_action" => proposal, "action_status" => "executing" }],
          ["Applied proposal", { "proposed_action" => proposal, "action_status" => "applied" }],
          ["Unknown proposal", { "proposed_action" => proposal, "action_status" => "unknown" }],
        ].each do |content, metadata|
          create(:ai_message, ai_conversation: conversation, role: "assistant", content:, metadata:)
        end

        history = controller.send(:agent_conversation_history, conversation)

        expect(history.map { |message| message[:proposal_state] }).to eq(
          [
            "no proposed action was recorded for this message",
            "a proposal was recorded, but its current result and card visibility are unknown; never send the creator back to that card",
            "execution started; do not confirm again",
            "the action was applied and cannot be confirmed again",
            "the result is unknown; do not confirm again",
          ],
        )
        # Every proposal turn's own creator-facing copy is gone from what the model sees; only the
        # turn with no proposal keeps its text.
        expect(history.map { |message| message[:content] }).to eq(
          [
            "No proposal",
            "You proposed a change on this turn.",
            "You proposed a change on this turn.",
            "You proposed a change on this turn.",
            "You proposed a change on this turn.",
          ],
        )
      end

      # gp#1470's production shape: a proposal applied earlier, then a turn whose persisted copy
      # points the creator back at that card. Replaying it let the model repeat it as live.
      it "replaces an applied proposal turn's confirm-that-card copy with server-owned state" do
        conversation = create(:ai_conversation, seller:)
        proposal = { "type" => "api_write", "params" => { "endpoint" => "update_user_custom_html" } }
        create(:ai_message, ai_conversation: conversation, content: "Upload the portrait")
        applied = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "The portrait upload is the proposal already sitting in front of you from my earlier turn — confirm that card and it goes through.",
          metadata: { "proposed_action" => proposal, "action_status" => "applied", "client_turn_id" => "8f14e45f", "objects" => [{ "id" => "prod_1" }] },
        )

        history = controller.send(:agent_conversation_history, conversation)

        expect(history.last).to eq(
          role: "assistant",
          content: "You proposed a change on this turn.",
          proposal_state: "the action was applied and cannot be confirmed again",
        )
        replayed = history.map { |message| message.values.join(" ") }.join(" ")
        expect(replayed).not_to include("confirm that card")
        expect(replayed).not_to include("update_user_custom_html")
        expect(replayed).not_to include("8f14e45f")
        expect(replayed).not_to include("prod_1")
        # The creator's own transcript is untouched — this only changes what the model is told.
        expect(applied.reload.content).to include("confirm that card")
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

      it "persists nothing when the service raises, so a failed turn is not replayed later" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond).and_raise(Ai::StoreAgentService::Error, "Too long.")

        expect do
          post :create, params: valid_params, format: :json
        end.to not_change { seller.ai_conversations.count }.and not_change { AiMessage.count }

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "replaces an unpersisted proposal with an honest non-confirmable reply" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond).and_return(store_agent_turn(
          reply: "Confirm this discount.",
          proposed_action: { "type" => "api_write", "params" => { "endpoint" => "create_offer_code" } },
        ))

        allow(controller).to receive(:persist_agent_turn!).and_raise(ActiveRecord::StatementInvalid)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))

        post :create, params: valid_params, format: :json

        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["reply"]).to eq(
          "I couldn't save that proposed change, so there is nothing to confirm. Please ask me to prepare it again.",
        )
        expect(response.parsed_body["conversation_id"]).to be_nil
        expect(response.parsed_body["proposed_action"]).to be_nil
        expect(response.parsed_body).not_to have_key("proposal_message_id")
      end

      it "still returns a non-proposal reply when persistence fails" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond).and_return(store_agent_turn(reply: "Sales are up.", proposed_action: nil))
        allow(controller).to receive(:persist_agent_turn!).and_raise(ActiveRecord::StatementInvalid)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))

        post :create, params: valid_params, format: :json

        expect(response).to be_successful
        expect(response.parsed_body["reply"]).to eq("Sales are up.")
      end

      it "rolls back both messages when the outcome does not match the proposed action" do
        proposal = { "type" => "api_write", "params" => { "endpoint" => "create_offer_code" } }
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
          post :create, params: valid_params, format: :json
        end.to not_change { seller.ai_conversations.count }.and not_change { AiMessage.count }

        expect(response).to be_successful
        expect(response.parsed_body["reply"]).to eq(
          "I couldn't save that proposed change, so there is nothing to confirm. Please ask me to prepare it again.",
        )
        expect(response.parsed_body["proposed_action"]).to be_nil
        expect(response.parsed_body).not_to have_key("outcome")
      end

      it "rejects and replaces server-owned confirmation copy without a proposal" do
        service_double = instance_double(Ai::StoreAgentService)
        allow(Ai::StoreAgentService).to receive(:new).and_return(service_double)
        allow(service_double).to receive(:respond).and_return(store_agent_turn(
          reply: Ai::StoreAgentService::PROPOSAL_READY_REPLY,
          proposed_action: nil,
        ))
        expect(ErrorNotifier).to receive(:notify).with(
          an_instance_of(ArgumentError).and(having_attributes(
            message: "Store agent proposal reply requires a proposed action.",
          )),
        )

        expect do
          post :create, params: valid_params, format: :json
        end.to not_change { seller.ai_conversations.count }.and not_change { AiMessage.count }

        expect(response).to be_successful
        expect(response.parsed_body["reply"]).to eq(Ai::StoreAgentService::NOTHING_STAGED_REPLY)
        expect(response.parsed_body["proposed_action"]).to be_nil
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

      it_behaves_like "an explained agent rate limit" do
        subject do
          exhaust_agent_request_throttle(throttle_key)
          post :create, params: valid_params, format: :json
        end
      end
    end
  end

  describe "POST execute" do
    let(:confirmed_action_params) { { endpoint: "create_offer_code", code: "LAUNCH", percent_off: 20 } }
    let(:conversation) { create(:ai_conversation, seller:) }
    let(:proposal_message) do
      create(
        :ai_message,
        ai_conversation: conversation,
        role: "assistant",
        content: "I can create that discount.",
        metadata: {
          "proposed_action" => {
            "type" => "api_write",
            "summary" => "Create discount LAUNCH",
            "params" => confirmed_action_params,
          },
        },
      )
    end
    let(:valid_params) do
      {
        type: "api_write",
        params: confirmed_action_params,
        conversation_id: conversation.external_id,
        proposal_message_id: proposal_message.external_id,
      }
    end

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

      it "matches an unchanged decimal after the browser serializes it as an integer" do
        proposal_message.update!(
          metadata: proposal_message.metadata.deep_merge(
            "proposed_action" => { "params" => { "percent_off" => 20.0 } },
          ),
        )
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        expect(executor_double).to receive(:execute).once do |type:, params:|
          expect(type).to eq("api_write")
          expect(params["percent_off"]).to eql(20)
          { success: true, message: "Created discount code LAUNCH." }
        end

        post :execute, params: valid_params, format: :json

        expect(response).to be_successful
        expect(proposal_message.reload.metadata["action_status"]).to eq("applied")
      end

      it "matches an unchanged decimal sent as an ordinary form string" do
        proposal_message.update!(
          metadata: proposal_message.metadata.deep_merge(
            "proposed_action" => { "params" => { "percent_off" => 20.0 } },
          ),
        )
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        expect(executor_double).to receive(:execute).once do |type:, params:|
          expect(type).to eq("api_write")
          expect(params["percent_off"]).to eql(20)
          { success: true, message: "Created discount code LAUNCH." }
        end

        post :execute,
             params: valid_params.deep_merge(params: { percent_off: "20" }),
             format: :json

        expect(response).to be_successful
        expect(proposal_message.reload.metadata["action_status"]).to eq("applied")
      end

      it "rejects large-exponent and non-finite numeric comparisons without expanding them" do
        expect(controller.send(:action_payload_values_match?, BigDecimal("1e1000000"), BigDecimal("1e1000000"))).to be(false)
        expect(controller.send(:action_payload_values_match?, BigDecimal("1e-1000000"), 0)).to be(false)
        expect(controller.send(:action_payload_values_match?, Float::INFINITY, Float::INFINITY)).to be(false)
      end

      it "rejects a numeric-looking string changed to an equivalent number before dispatch" do
        proposal_message.update!(
          metadata: proposal_message.metadata.deep_merge(
            "proposed_action" => { "params" => { "name" => "1e3" } },
          ),
        )
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute,
             params: valid_params.deep_merge(params: { name: "1000" }),
             format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "rejects scientific notation for a stored numeric before dispatch" do
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute,
             params: valid_params.deep_merge(params: { percent_off: "2e1" }),
             format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "marks the exact stored proposal applied" do
        create(:ai_message, ai_conversation: conversation, content: "Create a discount")
        # A different, newer pending proposal in the same chat must NOT be the one marked applied —
        # the persisted message id identifies which proposal was confirmed.
        other_proposal = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "I can also refund that sale.",
          metadata: { "proposed_action" => { "type" => "api_write", "params" => { "endpoint" => "refund_sale" } } },
        )

        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(
          success: true,
          message: "Created discount code LAUNCH.",
          object: { "type" => "discount", "title" => "LAUNCH", "fields" => [] },
        )

        post :execute, params: valid_params, format: :json

        expect(response).to be_successful
        metadata = proposal_message.reload.metadata
        expect(metadata["action_status"]).to eq("applied")
        # The created object replaces the turn's lookup objects, matching what the live UI shows.
        expect(metadata["objects"]).to eq([{ "type" => "discount", "title" => "LAUNCH", "fields" => [] }])
        # The unrelated pending proposal is untouched.
        expect(other_proposal.reload.metadata["action_status"]).to be_nil
      end

      it "bumps the conversation's updated_at when a proposal is marked applied" do
        # Confirming an action counts as conversation activity: the resume-latest endpoint orders
        # by updated_at, so a stale timestamp here would make a refresh resume a DIFFERENT, more
        # recently active conversation than the one the seller just acted in.
        proposal_message
        stale_time = 1.hour.ago
        conversation.update_column(:updated_at, stale_time)

        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount code LAUNCH.")

        post :execute, params: valid_params, format: :json

        expect(response).to be_successful
        expect(conversation.reload.updated_at).to be > stale_time
      end

      it "releases the claim when the executor rejects before dispatch so confirmation can be retried" do
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute)
          .and_return(
            { success: false, message: "Nope.", retry_safe: true },
            { success: true, message: "Created discount code LAUNCH." },
          )

        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq("success" => false, "message" => "Nope.", "retryable" => true)
        expect(proposal_message.reload.metadata["action_status"]).to be_nil

        post :execute, params: valid_params, format: :json

        expect(response).to be_successful
        expect(proposal_message.reload.metadata["action_status"]).to eq("applied")
      end

      it "keeps the claim when the nested API reports failure after dispatch" do
        proposal_message
        stale_time = 1.hour.ago
        conversation.update_column(:updated_at, stale_time)
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(
          success: false,
          message: "That change couldn't be saved.",
          failure_reason: "api_failure",
        )

        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include("action_status" => "unknown")
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
        expect(conversation.reload.updated_at).to be > stale_time
      end

      it "rolls back the pre-dispatch claim when touching the conversation fails" do
        proposal_message
        allow_any_instance_of(AiConversation).to receive(:touch).and_raise(ActiveRecord::StatementInvalid)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        expect do
          post :execute, params: valid_params, format: :json
        end.to raise_error(ActiveRecord::StatementInvalid)

        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "does not reload the proposal after committing its claim and before dispatch" do
        proposal_message
        expect_any_instance_of(AiMessage).not_to receive(:reload)
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        expect(executor_double).to receive(:execute).and_return(
          success: false,
          message: "Rejected before dispatch.",
          retry_safe: true,
        )

        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        stored_metadata = AiMessage.where(id: proposal_message.id).pick(:metadata)
        expect(stored_metadata["action_status"]).to be_nil
      end

      it "keeps the claim when the executor raises after dispatch may have committed" do
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_raise(ActiveRecord::StatementInvalid)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))

        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body).to include(
          "message" => "The action may have completed, so it can't be retried automatically.",
          "action_status" => "unknown",
        )
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
      end

      it "still reports success when recording the applied status fails after the action committed" do
        # The store change has already committed by the time the bookkeeping write runs. Returning
        # an error here would prompt the seller to retry the confirmation and run the action twice
        # (a duplicate discount, refund, etc.), so persistence failures must not mask the success.
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount code LAUNCH.")
        allow(controller).to receive(:record_agent_action_applied!).and_raise(ActiveRecord::StatementInvalid)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::StatementInvalid))

        post :execute, params: valid_params, format: :json

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true, "message" => "Created discount code LAUNCH.")
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
      end

      it "rejects a tampered payload before dispatch" do
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute,
             params: valid_params.deep_merge(params: { percent_off: 100 }),
             format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
        expect(response.parsed_body).not_to have_key("retryable")
        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "rejects an unmatched proposal message before dispatch" do
        unrelated_message = create(:ai_message, ai_conversation: conversation, role: "assistant")
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute,
             params: valid_params.merge(proposal_message_id: unrelated_message.external_id),
             format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
      end

      it "rejects a duplicate confirmation without replaying the action" do
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        expect(executor_double).to receive(:execute).once.and_return(
          success: true,
          message: "Created discount code LAUNCH.",
        )

        post :execute, params: valid_params, format: :json
        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include(
          "message" => "That proposal has already been confirmed.",
          "action_status" => "applied",
        )
      end

      it "settles a stale exact-id confirmation as unknown without dispatch" do
        proposal_message.update_columns(
          metadata: proposal_message.metadata.merge("action_status" => "executing"),
          updated_at: database_now - execution_abandoned_after - 1.second,
        )
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include(
          "message" => "That proposal has already been confirmed.",
          "action_status" => "unknown",
        )
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
      end

      it "settles a stale legacy no-id confirmation as unknown without dispatch" do
        proposal_message.update_columns(
          metadata: proposal_message.metadata.merge("action_status" => "executing"),
          updated_at: database_now - execution_abandoned_after - 1.second,
        )
        allow(ErrorNotifier).to receive(:notify)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.except(:proposal_message_id), format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include(
          "message" => "That proposal has already been confirmed.",
          "action_status" => "unknown",
        )
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
      end

      it "returns the winning claim state when another confirmation is still executing" do
        allow(controller).to receive(:compare_and_set_agent_action_claim) do
          proposal_message.update_column(:metadata, proposal_message.metadata.merge("action_status" => "executing"))
          0
        end
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params, format: :json

        expect(controller).to have_received(:compare_and_set_agent_action_claim).once
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include(
          "message" => "That proposal has already been confirmed.",
          "action_status" => "executing",
        )
      end

      it "claims and dispatches when a safe release wins after the initial status read" do
        proposal_message.update!(metadata: proposal_message.metadata.merge("action_status" => "executing"))
        released = false
        allow(controller).to receive(:reconcile_stale_agent_action!).and_wrap_original do |method, message|
          unless released
            released = true
            expect(controller.send(:release_agent_action_claim!, message)).to be(true)
          end
          method.call(message)
        end
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        expect(executor_double).to receive(:execute).once.and_return(
          success: true,
          message: "Created discount code LAUNCH.",
        )

        post :execute, params: valid_params, format: :json

        expect(response).to be_successful
        expect(proposal_message.reload.metadata["action_status"]).to eq("applied")
      end

      it "returns a retry-safe pending result after two concurrent safe releases" do
        allow(controller).to receive(:compare_and_set_agent_action_claim) do |message|
          message.update_column(:metadata, message.metadata.merge("action_status" => "executing"))
          expect(controller.send(:release_agent_action_claim!, message)).to be(true)
          0
        end
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params, format: :json

        expect(controller).to have_received(:compare_and_set_agent_action_claim).twice
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => "That proposal is pending and can be confirmed again.",
          "retryable" => true,
        )
        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "settles a stale claim loaded after a lost compare-and-set without dispatch" do
        allow(controller).to receive(:compare_and_set_agent_action_claim) do
          proposal_message.update_columns(
            metadata: proposal_message.metadata.merge("action_status" => "executing"),
            updated_at: database_now - execution_abandoned_after - 1.second,
          )
          0
        end
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params, format: :json

        expect(controller).to have_received(:compare_and_set_agent_action_claim).once
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include(
          "message" => "That proposal has already been confirmed.",
          "action_status" => "unknown",
        )
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
      end

      it "claims a pending proposal only once before dispatch" do
        first_claim, first_error, first_status = controller.send(
          :claim_agent_action,
          conversation,
          proposal_message_id: proposal_message.external_id,
          type: "api_write",
          action_params: confirmed_action_params,
        )
        second_claim, second_error, second_status = controller.send(
          :claim_agent_action,
          conversation,
          proposal_message_id: proposal_message.external_id,
          type: "api_write",
          action_params: confirmed_action_params,
        )

        expect(first_claim).to eq(proposal_message)
        expect(first_error).to be_nil
        expect(first_status).to be_nil
        expect(second_claim).to be_nil
        expect(second_error).to eq("That proposal has already been confirmed.")
        expect(second_status).to eq("executing")
      ensure
        controller.send(:release_agent_action_claim!, first_claim) if first_claim
      end

      it "lets a safe pre-dispatch release beat stale recovery and permits a fresh claim" do
        first_claim, = controller.send(
          :claim_agent_action,
          conversation,
          proposal_message_id: proposal_message.external_id,
          type: "api_write",
          action_params: confirmed_action_params,
        )
        proposal_message.update_column(:updated_at, database_now - execution_abandoned_after - 1.second)
        stale_reader = AiMessage.find(proposal_message.id)

        expect(controller.send(:release_agent_action_claim!, first_claim)).to be(true)
        expect(controller.send(:reconcile_stale_agent_action!, stale_reader)).to be_nil
        expect(proposal_message.reload.metadata["action_status"]).to be_nil

        second_claim, second_error, second_status = controller.send(
          :claim_agent_action,
          conversation,
          proposal_message_id: proposal_message.external_id,
          type: "api_write",
          action_params: confirmed_action_params,
        )
        expect(second_claim).to eq(proposal_message)
        expect(second_error).to be_nil
        expect(second_status).to be_nil
      ensure
        controller.send(:release_agent_action_claim!, second_claim) if second_claim
      end

      it "does not let a stale reader overwrite a fresh claim after safe release" do
        first_claim, = controller.send(
          :claim_agent_action,
          conversation,
          proposal_message_id: proposal_message.external_id,
          type: "api_write",
          action_params: confirmed_action_params,
        )
        proposal_message.update_column(:updated_at, database_now - execution_abandoned_after - 1.second)
        stale_reader = AiMessage.find(proposal_message.id)

        expect(controller.send(:release_agent_action_claim!, first_claim)).to be(true)
        second_claim, second_error, second_status = controller.send(
          :claim_agent_action,
          conversation,
          proposal_message_id: proposal_message.external_id,
          type: "api_write",
          action_params: confirmed_action_params,
        )
        fresh_claimed_at = proposal_message.reload.updated_at

        expect(second_claim).to eq(proposal_message)
        expect(second_error).to be_nil
        expect(second_status).to be_nil
        expect(controller.send(:reconcile_stale_agent_action!, stale_reader)).to eq("executing")
        expect(proposal_message.reload.metadata["action_status"]).to eq("executing")
        expect(proposal_message.updated_at).to eq(fresh_claimed_at)
      ensure
        controller.send(:release_agent_action_claim!, second_claim) if second_claim
      end

      it "reports an unreleasable claim without inherited request context" do
        proposal_message.update!(metadata: proposal_message.metadata.merge("action_status" => "applied"))
        expect(ErrorNotifier).to receive(:notify).with(
          "Store agent action claim could not be released",
          exclude_request_context: true,
          ai_message_id: proposal_message.id,
        )

        expect(controller.send(:release_agent_action_claim!, proposal_message)).to be(false)
      end

      it "reports an unknown-outcome persistence failure without inherited request context" do
        proposal_message.update!(metadata: proposal_message.metadata.merge("action_status" => "executing"))
        persistence_error = ActiveRecord::StatementInvalid.new("write failed")
        allow(AiMessage).to receive(:transaction).and_raise(persistence_error)
        expect(ErrorNotifier).to receive(:notify).with(
          persistence_error,
          exclude_request_context: true,
          ai_message_id: proposal_message.id,
        )

        expect(controller.send(:record_agent_action_outcome_unknown!, proposal_message)).to eq("executing")
      end

      it "accepts an old client only when its payload uniquely matches a pending proposal" do
        expect(ErrorNotifier).to receive(:notify).with(
          "Store agent confirmation omitted proposal message id",
          exclude_request_context: true,
        )
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount code LAUNCH.")

        post :execute, params: valid_params.except(:proposal_message_id), format: :json

        expect(response).to be_successful
        expect(proposal_message.reload.metadata["action_status"]).to eq("applied")
      end

      it "rejects an old-client payload that also matches a completed proposal" do
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          metadata: {
            "proposed_action" => { "type" => "api_write", "params" => confirmed_action_params },
            "action_status" => "applied",
          },
        )
        allow(ErrorNotifier).to receive(:notify)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.except(:proposal_message_id), format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "rejects an old-client retry that matches a completed proposal older than one day" do
        completed_proposal = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          metadata: {
            "proposed_action" => { "type" => "api_write", "params" => confirmed_action_params },
            "action_status" => "applied",
          },
        )
        completed_proposal.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)
        proposal_message
        allow(ErrorNotifier).to receive(:notify)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.except(:proposal_message_id), format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "rejects legacy confirmation when the full proposal scope exceeds the scan cap" do
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          metadata: {
            "proposed_action" => { "type" => "api_write", "params" => confirmed_action_params },
            "action_status" => "applied",
          },
        )
        create_list(:ai_message, 1001, ai_conversation: conversation, role: "assistant")
        proposal_message
        allow(ErrorNotifier).to receive(:notify)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.except(:proposal_message_id), format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
        expect(proposal_message.reload.metadata["action_status"]).to be_nil
      end

      it "rejects an ambiguous old-client payload before dispatch" do
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          metadata: { "proposed_action" => { "type" => "api_write", "params" => confirmed_action_params } },
        )
        allow(ErrorNotifier).to receive(:notify)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.except(:proposal_message_id), format: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["message"]).to include("doesn't match")
      end

      it "404s without executing when the conversation belongs to another seller" do
        other_conversation = create(:ai_conversation)

        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params.merge(conversation_id: other_conversation.external_id), format: :json

        expect(response).to have_http_status(:not_found)
      end

      it "rejects an unsupported action type" do
        post :execute, params: valid_params.merge(type: "delete_account"), format: :json

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

      it "puts fixed failure metadata and the catalog endpoint id in the request's log payload" do
        # The 422s from this endpoint are a bucket (permission denials, unknown-key rejections, API
        # validation failures all land here). Fixed categories, the upstream status, and a
        # catalog-resolved endpoint separate those causes without copying seller or API text into
        # Elasticsearch.
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(
          success: false,
          message: "You don't have permission to do that.",
          failure_reason: "permission_denied",
          failure_status: 403,
        )

        payload = {}
        post :execute, params: valid_params, format: :json
        controller.send(:append_info_to_payload, payload)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => "You don't have permission to do that.",
          "action_status" => "unknown",
        )
        expect(payload[:agent_action_failure_reason]).to eq("permission_denied")
        expect(payload[:agent_action_failure_status]).to eq(403)
        expect(payload[:agent_action_endpoint]).to eq("create_offer_code")
      end

      it "never copies a reflected API validation value into the request's log payload" do
        # The v2 API can echo a rejected callback URL, including its query credentials. The seller
        # still needs that exact message, but the long-lived log gets only a fixed category and
        # integer status.
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        secret = "seller-secret-token"
        reflected = "Invalid post URL 'not-a-url?token=#{secret}'"
        allow(executor_double).to receive(:execute).and_return(
          success: false,
          message: reflected,
          failure_reason: "api_failure",
          failure_status: 422,
        )

        payload = {}
        post :execute, params: valid_params, format: :json
        controller.send(:append_info_to_payload, payload)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq(
          "success" => false,
          "message" => reflected,
          "action_status" => "unknown",
        )
        expect(payload).to include(
          agent_action_failure_reason: "api_failure",
          agent_action_failure_status: 422,
          agent_action_endpoint: "create_offer_code",
        )
        expect(payload.to_json).not_to include(secret)
      end

      it "omits the endpoint from the log payload when the confirmed action names one the catalog doesn't have" do
        # The endpoint is what these 422s get grouped by, so it is resolved through the catalog
        # rather than copied from the request — a tampered or stale proposal naming something the
        # catalog doesn't have contributes no value of its own choosing to the metric.
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(
          success: false,
          message: "That action isn't supported.",
          failure_reason: "unsupported_action",
          retry_safe: true,
        )

        unknown_action_params = { endpoint: "not_a_real_endpoint" }
        proposal_message.update!(
          metadata: { "proposed_action" => { "type" => "api_write", "params" => unknown_action_params } },
        )
        payload = {}
        post :execute, params: valid_params.merge(params: unknown_action_params), format: :json
        controller.send(:append_info_to_payload, payload)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(payload[:agent_action_failure_reason]).to eq("unsupported_action")
        expect(payload).not_to have_key(:agent_action_endpoint)
      end

      it "does not add failure fields to the log payload when the confirmed action succeeds" do
        executor_double = instance_double(Ai::StoreAgentActionExecutor)
        allow(Ai::StoreAgentActionExecutor).to receive(:new).and_return(executor_double)
        allow(executor_double).to receive(:execute).and_return(success: true, message: "Created discount code LAUNCH.")

        payload = {}
        post :execute, params: valid_params, format: :json
        controller.send(:append_info_to_payload, payload)

        expect(response).to be_successful
        expect(payload).not_to have_key(:agent_action_failure_reason)
        expect(payload).not_to have_key(:agent_action_endpoint)
      end

      it "halts on throttle without invoking the action executor" do
        exhaust_agent_request_throttle(throttle_key)
        expect(Ai::StoreAgentActionExecutor).not_to receive(:new)

        post :execute, params: valid_params, format: :json

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers["Retry-After"]).to be_present
      end

      it_behaves_like "an explained agent rate limit" do
        subject do
          exhaust_agent_request_throttle(throttle_key)
          post :execute, params: valid_params, format: :json
        end
      end
    end
  end
end
