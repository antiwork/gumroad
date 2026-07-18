# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authentication_required"
require "shared_examples/authorize_called"

describe Api::Internal::AgentConversationsController do
  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

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
        create(
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
              "objects" => [{ "type" => "product", "title" => "Masterclass", "fields" => [] }],
              "action_status" => "applied",
            },
          ]
        )
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
        create(
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
          },
        )
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
