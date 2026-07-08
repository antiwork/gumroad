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
end
