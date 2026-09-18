# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Api::Internal::AgentMessagesController do
  let(:seller) { create(:named_seller) }
  let(:client) { instance_double(Ai::AnthropicClient) }

  include_context "with user signed in as admin for seller"

  before do
    allow_any_instance_of(User).to receive(:eligible_for_store_agent?).and_return(true)
    allow(Ai::AnthropicClient).to receive(:new).and_return(client)
    Feature.activate_user(:custom_html_pages, seller)
  end

  def tool(name, input)
    Ai::AnthropicClient::Result.new(text: "", stop_reason: "tool_use", tool_uses: [{ id: "synthetic-tool", name:, input: }])
  end

  %w[user product].each do |surface|
    context "undoing #{surface} formatting" do
      let(:pageable) { surface == "user" ? seller : create(:product, user: seller) }
      let(:path_params) { surface == "user" ? {} : { "id" => pageable.external_id } }
      let(:original) { "<p>Keep this instruction.</p>" }
      let(:formatted) { "<p><strong>Keep this instruction.</strong></p>" }

      it "persists only a server receipt and proposes the exact inverse with a fresh one-shot confirmation" do
        pageable.update!(custom_html: original + '<a data-gumroad-action="buy">Buy</a>')
        original_page = pageable.reload.custom_html
        allow(client).to receive(:messages).and_return(
          tool("api_read", { "endpoint" => "get_#{surface}_custom_html", "path_params" => path_params }),
          tool("api_write", { "endpoint" => "edit_#{surface}_custom_html", "path_params" => path_params, "params" => { "find" => original, "replace" => formatted } }),
          tool("complete_turn", { "outcome" => "proposal_ready" }),
        )
        post :create, params: { messages: [{ role: "user", content: "Bold the instruction on my #{surface} page." }] }, as: :json
        expect(response).to be_successful
        first = response.parsed_body
        expect(first.fetch("proposed_action")).to be_present
        expect(pageable.reload.custom_html).to eq(original_page)

        post :execute, params: first.fetch("proposed_action").slice("type", "params").merge(first.slice("conversation_id", "proposal_message_id")), as: :json
        expect(response.parsed_body["success"]).to be(true), response.parsed_body.inspect
        expect(response.parsed_body).not_to have_key("html_undo")
        conversation = seller.ai_conversations.sole
        applied_message = conversation.ai_messages.role_assistant.last
        expect(applied_message.reload.metadata.fetch("html_undo")).to be_present
        expect(controller.send(:agent_conversation_history, conversation).to_json).not_to include("html_undo", "expected_custom_html_sha256", formatted)
        expect(controller.send(:agent_conversation_props, conversation).to_json).not_to include("html_undo", "expected_custom_html_sha256", "action_started_at")
        expect(applied_message.metadata.fetch("action_started_at")).to match(Ai::StoreAgentHtmlUndo::ACTION_STARTED_AT_FORMAT)
        formatted_page = pageable.reload.custom_html

        allow(client).to receive(:messages).and_return(
          tool("prepare_html_undo", {}),
          tool("complete_turn", { "outcome" => "proposal_ready" }),
        )
        post :create, params: {
          conversation_id: conversation.external_id,
          messages: [{ role: "user", content: "Undo that formatting, keeping the instruction." }],
          html_undo: { "params" => { "find" => formatted, "replace" => "" } },
        }, as: :json

        expect(response).to be_successful
        inverse = response.parsed_body
        expect(inverse.fetch("proposed_action").dig("params", "params")).to include("find" => formatted, "replace" => original)
        expect(pageable.reload.custom_html).to eq(formatted_page)
        expect(inverse.fetch("proposal_message_id")).not_to eq(first.fetch("proposal_message_id"))
        confirmation = inverse.fetch("proposed_action").slice("type", "params").merge(inverse.slice("conversation_id", "proposal_message_id"))
        post :execute, params: confirmation, as: :json
        expect(response.parsed_body["success"]).to be(true), response.parsed_body.inspect
        expect(pageable.reload.custom_html).to eq(original_page)

        post :execute, params: confirmation, as: :json
        expect(response.parsed_body["success"]).to be(false)
        expect(pageable.reload.custom_html).to eq(original_page)
      end
    end
  end
end
