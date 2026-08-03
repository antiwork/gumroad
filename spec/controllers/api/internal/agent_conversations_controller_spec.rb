# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"

describe Api::Internal::AgentConversationsController do
  let(:seller) { create(:named_seller) }
  let(:execution_abandoned_after) do
    AgentConversationPersistence.const_get(:ACTION_EXECUTION_ABANDONED_AFTER, false)
  end
  let(:database_now) { AiMessage.connection.select_value("SELECT CURRENT_TIMESTAMP(6)") }
  let(:boundary_test_margin) { 10.seconds }

  include_context "with user signed in as admin for seller"

  before do
    allow_any_instance_of(User).to receive(:eligible_for_store_agent?).and_return(true)
  end

  describe "GET latest" do
    it_behaves_like "authentication required for action", :get, :latest

    it_behaves_like "authorize called for action", :get, :latest do
      let(:record) { seller }
      let(:policy_method) { :use_store_agent? }
      let(:request_format) { :json }
    end

    context "when authenticated and authorized" do
      it "returns null when the seller has no conversations" do
        get :latest, format: :json

        expect(response).to be_successful
        expect(response.parsed_body).to eq("success" => true, "conversation" => nil)
      end

      it "returns the most recently active conversation with its full transcript" do
        older = create(:ai_conversation, seller:, title: "Old chat")
        create(:ai_message, ai_conversation: older)
        newer = create(:ai_conversation, seller:, title: "How are my sales?")
        create(:ai_message, ai_conversation: newer, content: "How are my sales?")
        proposal_message = create(
          :ai_message,
          ai_conversation: newer,
          role: "assistant",
          content: "Sales are up.",
          metadata: {
            "proposed_action" => { "type" => "api_write", "summary" => "Create a discount" },
            "objects" => [{ "type" => "product", "title" => "Masterclass", "fields" => [] }],
            "action_status" => "applied",
          },
        )
        # Activity (a new message) on the older conversation makes it the one to resume, even
        # though it was created first — recency follows updated_at, not creation order.
        create(:ai_message, ai_conversation: older, content: "Follow-up")
        older.update!(updated_at: 1.minute.from_now)

        get :latest, format: :json

        expect(response.parsed_body["conversation"]["id"]).to eq(older.external_id)

        # Bring the newer conversation back on top and check the full message shape.
        newer.update!(updated_at: 2.minutes.from_now)
        get :latest, format: :json

        conversation = response.parsed_body["conversation"]
        expect(conversation["id"]).to eq(newer.external_id)
        expect(conversation["title"]).to eq("How are my sales?")
        expect(conversation["messages"]).to eq(
          [
            { "role" => "user", "content" => "How are my sales?" },
            {
              "role" => "assistant",
              "content" => "Sales are up.",
              "proposed_action" => { "type" => "api_write", "summary" => "Create a discount" },
              "proposal_message_id" => proposal_message.external_id,
              "objects" => [{ "type" => "product", "title" => "Masterclass", "fields" => [] }],
              "action_status" => "applied",
            },
          ]
        )
      end

      it "durably settles an abandoned execution while hydrating the web conversation" do
        conversation = create(:ai_conversation, seller:)
        proposal_message = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          metadata: {
            "proposed_action" => { "type" => "api_write", "params" => { "endpoint" => "update_product" } },
            "action_status" => "executing",
          },
        )
        proposal_message.update_column(:updated_at, database_now - execution_abandoned_after - 1.second)
        conversation_activity_at = conversation.reload.updated_at

        get :latest, format: :json

        expect(response.parsed_body.dig("conversation", "messages", 0, "action_status")).to eq("unknown")
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
        expect(conversation.reload.updated_at).to eq(conversation_activity_at)
      end

      it "caps hydration at the most recent HISTORY_MAX_MESSAGES messages" do
        stub_const("AgentConversationPersistence::HISTORY_MAX_MESSAGES", 3)
        conversation = create(:ai_conversation, seller:)
        5.times { |i| create(:ai_message, ai_conversation: conversation, content: "Message #{i + 1}") }

        get :latest, format: :json

        messages = response.parsed_body["conversation"]["messages"]
        expect(messages.map { |m| m["content"] }).to eq(["Message 3", "Message 4", "Message 5"])
      end

      it "skips soft-deleted conversations" do
        conversation = create(:ai_conversation, seller:)
        conversation.mark_deleted!

        get :latest, format: :json

        expect(response.parsed_body["conversation"]).to be_nil
      end

      it "never returns another seller's conversation" do
        create(:ai_conversation) # belongs to a different seller

        get :latest, format: :json

        expect(response.parsed_body["conversation"]).to be_nil
      end
    end
  end

  describe "GET action_status" do
    let(:conversation) { create(:ai_conversation, seller:) }
    let(:proposal_message) do
      create(
        :ai_message,
        ai_conversation: conversation,
        role: "assistant",
        metadata: {
          "proposed_action" => { "type" => "api_write", "params" => { "endpoint" => "update_product" } },
        },
      )
    end

    it "recognizes the exact status route used by the web poller" do
      path = internal_agent_action_status_path(proposal_message_id: proposal_message.external_id)
      uri = URI.parse(path)
      expect(uri.path).to eq("/internal/agent/actions/status")
      expect(Rack::Utils.parse_query(uri.query)).to eq("proposal_message_id" => proposal_message.external_id)
      expect(get: "http://#{ROOT_DOMAIN}#{uri.path}").to route_to(
        controller: "api/internal/agent_conversations",
        action: "action_status",
        format: :json,
      )
    end

    it_behaves_like "authentication required for action", :get, :action_status do
      let(:request_params) { { proposal_message_id: proposal_message.external_id } }
    end

    it_behaves_like "authorize called for action", :get, :action_status do
      let(:record) { seller }
      let(:policy_method) { :use_store_agent? }
      let(:request_params) { { proposal_message_id: proposal_message.external_id } }
      let(:request_format) { :json }
    end

    context "when authenticated and authorized" do
      it "returns the exact proposal's pending state" do
        get :action_status, params: { proposal_message_id: proposal_message.external_id }, format: :json

        expect(response.parsed_body).to eq("success" => true, "action_status" => "pending", "objects" => [])
      end

      it "returns each persisted claimed state" do
        %w[executing applied unknown].each do |action_status|
          proposal_message.update_column(
            :metadata,
            proposal_message.metadata.merge("action_status" => action_status),
          )

          get :action_status, params: { proposal_message_id: proposal_message.external_id }, format: :json

          expect(response.parsed_body).to eq("success" => true, "action_status" => action_status, "objects" => [])
        end
      end

      it "keeps an executing claim within the server abandonment threshold" do
        proposal_message.update_columns(
          metadata: proposal_message.metadata.merge("action_status" => "executing"),
          updated_at: database_now - execution_abandoned_after + boundary_test_margin,
        )

        get :action_status, params: { proposal_message_id: proposal_message.external_id }, format: :json

        expect(response.parsed_body).to eq("success" => true, "action_status" => "executing", "objects" => [])
        expect(proposal_message.reload.metadata["action_status"]).to eq("executing")
      end

      it "settles before the frontend's final reconciliation poll and deadline" do
        frontend_final_poll_ms = 127_500
        frontend_deadline_ms = 130_000
        server_stale_horizon_ms = execution_abandoned_after.in_milliseconds

        expect(server_stale_horizon_ms).to eq(120_000)
        expect(server_stale_horizon_ms).to be < frontend_final_poll_ms
        expect(frontend_final_poll_ms).to be < frontend_deadline_ms
      end

      it "durably settles an executing claim just after the server abandonment threshold" do
        proposal_message.update_columns(
          metadata: proposal_message.metadata.merge("action_status" => "executing"),
          updated_at: database_now - execution_abandoned_after - 1.second,
        )

        get :action_status, params: { proposal_message_id: proposal_message.external_id }, format: :json

        expect(response.parsed_body).to eq("success" => true, "action_status" => "unknown", "objects" => [])
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
      end

      it "does not overwrite a concurrent applied finalization from a stale loaded row" do
        proposal_message.update_columns(
          metadata: proposal_message.metadata.merge("action_status" => "executing"),
          updated_at: database_now - execution_abandoned_after - 1.second,
        )
        stale_reader = AiMessage.find(proposal_message.id)
        controller.send(
          :record_agent_action_applied!,
          AiMessage.find(proposal_message.id),
          object: { "type" => "discount", "title" => "LAUNCH", "fields" => [] },
        )

        expect(controller.send(:reconcile_stale_agent_action!, stale_reader)).to eq("applied")
        expect(proposal_message.reload.metadata).to include(
          "action_status" => "applied",
          "objects" => [{ "type" => "discount", "title" => "LAUNCH", "fields" => [] }],
        )
      end

      it "does not let a late finalization overwrite a recovered unknown outcome" do
        proposal_message.update_columns(
          metadata: proposal_message.metadata.merge("action_status" => "executing"),
          updated_at: database_now - execution_abandoned_after - 1.second,
        )

        expect(controller.send(:reconcile_stale_agent_action!, proposal_message)).to eq("unknown")
        expect do
          controller.send(:record_agent_action_applied!, AiMessage.find(proposal_message.id), object: nil)
        end.to raise_error(ActiveRecord::StaleObjectError)
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
      end

      it "returns the persisted action result objects" do
        result_object = {
          "type" => "product",
          "title" => "Updated product",
          "fields" => [{ "label" => "Price", "value" => "$25" }],
        }
        proposal_message.update_column(
          :metadata,
          proposal_message.metadata.merge("action_status" => "applied", "objects" => [result_object]),
        )

        get :action_status, params: { proposal_message_id: proposal_message.external_id }, format: :json

        expect(response.parsed_body).to eq(
          "success" => true,
          "action_status" => "applied",
          "objects" => [result_object],
        )
      end

      it "never returns another seller's proposal" do
        other_proposal = create(
          :ai_message,
          ai_conversation: create(:ai_conversation),
          role: "assistant",
          metadata: { "proposed_action" => { "type" => "api_write", "params" => {} } },
        )

        get :action_status, params: { proposal_message_id: other_proposal.external_id }, format: :json

        expect(response).to have_http_status(:not_found)
      end

      it "rejects a message that is not a proposal and an invalid external id" do
        message = create(:ai_message, ai_conversation: conversation, role: "assistant")

        [message.external_id, "not-an-external-id"].each do |proposal_message_id|
          get :action_status, params: { proposal_message_id: }, format: :json

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  describe "GET turn_status" do
    let(:client_turn_id) { SecureRandom.uuid }
    let(:turn_status_key) { RedisKey.agent_turn_status(seller.id, client_turn_id) }

    after { $redis.del(turn_status_key) }

    it_behaves_like "authentication required for action", :get, :turn_status do
      let(:request_params) { { client_turn_id: } }
    end

    it_behaves_like "authorize called for action", :get, :turn_status do
      let(:record) { seller }
      let(:policy_method) { :use_store_agent? }
      let(:request_params) { { client_turn_id: } }
      let(:request_format) { :json }
    end

    context "when authenticated and authorized" do
      it "returns the persisted turn with its conversation id and message" do
        conversation = create(:ai_conversation, seller:)
        create(:ai_message, ai_conversation: conversation, content: "what does my bio say")
        proposal_message = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Your bio has three lines.",
          metadata: {
            "client_turn_id" => client_turn_id,
            "proposed_action" => { "type" => "api_write", "summary" => "Update the bio" },
          },
        )

        get :turn_status, params: { client_turn_id: }, format: :json

        expect(response.parsed_body).to eq(
          "success" => true,
          "status" => "persisted",
          "conversation_id" => conversation.external_id,
          "message" => {
            "role" => "assistant",
            "content" => "Your bio has three lines.",
            "proposed_action" => { "type" => "api_write", "summary" => "Update the bio" },
            "proposal_message_id" => proposal_message.external_id,
          },
        )
      end

      it "settles abandoned action bookkeeping without making a recovered turn newly active" do
        conversation = create(:ai_conversation, seller:)
        proposal_message = create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "Confirm this change.",
          metadata: {
            "client_turn_id" => client_turn_id,
            "proposed_action" => { "type" => "api_write", "summary" => "Update the bio" },
            "action_status" => "executing",
          },
        )
        proposal_message.update_column(:updated_at, database_now - execution_abandoned_after - 1.second)
        conversation_activity_at = conversation.reload.updated_at

        get :turn_status, params: { client_turn_id: }, format: :json

        expect(response.parsed_body.dig("message", "action_status")).to eq("unknown")
        expect(proposal_message.reload.metadata["action_status"]).to eq("unknown")
        expect(conversation.reload.updated_at).to eq(conversation_activity_at)
      end

      it "returns in_progress while the streaming endpoint's liveness marker is armed" do
        $redis.set(turn_status_key, "in_progress", ex: 60)

        get :turn_status, params: { client_turn_id: }, format: :json

        expect(response.parsed_body).to eq("success" => true, "status" => "in_progress")
      end

      it "returns failed when the turn was marked as never going to persist" do
        $redis.set(turn_status_key, "failed", ex: 60)

        get :turn_status, params: { client_turn_id: }, format: :json

        expect(response.parsed_body).to eq("success" => true, "status" => "failed")
      end

      it "returns unknown when there is no stored turn and no marker" do
        get :turn_status, params: { client_turn_id: }, format: :json

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

        get :turn_status, params: { client_turn_id: }, format: :json

        expect(response.parsed_body).to eq("success" => true, "status" => "unknown")
      end

      it "does not find turns older than the recovery lookup window" do
        conversation = create(:ai_conversation, seller:)
        create(
          :ai_message,
          ai_conversation: conversation,
          role: "assistant",
          content: "An old reply.",
          metadata: { "client_turn_id" => client_turn_id },
          created_at: 2.hours.ago,
        )

        get :turn_status, params: { client_turn_id: }, format: :json

        expect(response.parsed_body).to eq("success" => true, "status" => "unknown")
      end

      it "rejects a malformed turn id" do
        get :turn_status, params: { client_turn_id: "not/a?valid*id" }, format: :json

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["success"]).to eq(false)
      end
    end
  end
end
