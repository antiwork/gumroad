# frozen_string_literal: true

require "spec_helper"

# Mobile counterpart of spec/controllers/api/internal/agent_messages_html_undo_spec.rb: the same
# synthetic model turns drive the real service, persistence, executor, and v2 API through the
# mobile bearer, so the receipt/undo contract is proven on both surfaces.
describe Api::Mobile::AgentController do
  let(:client) { instance_double(Ai::AnthropicClient) }

  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api")
    @auth_params = { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: @token.token }
    allow_any_instance_of(User).to receive(:eligible_for_store_agent?).and_return(true)
    allow(Ai::AnthropicClient).to receive(:new).and_return(client)
    Feature.activate_user(:custom_html_pages, @seller)
  end

  after { $redis.del(RedisKey.agent_request_throttle(@seller.id)) }

  def tool(name, input)
    Ai::AnthropicClient::Result.new(text: "", stop_reason: "tool_use", tool_uses: [{ id: "synthetic-tool", name:, input: }])
  end

  def confirmation_for(turn)
    turn.fetch("proposed_action").slice("type", "params").merge(turn.slice("conversation_id", "proposal_message_id"))
  end

  %w[user product].each do |surface|
    context "undoing #{surface} formatting" do
      let(:pageable) { surface == "user" ? @seller : create(:product, user: @seller) }
      let(:path_params) { surface == "user" ? {} : { "id" => pageable.external_id } }
      let(:original) { "<p>Keep this instruction.</p>" }
      let(:formatted) { "<p><strong>Keep this instruction.</strong></p>" }

      # define_method rather than def so the closure keeps `surface`.
      define_method(:apply_formatting_and_prepare_undo) do
        allow(client).to receive(:messages).and_return(
          tool("api_read", { "endpoint" => "get_#{surface}_custom_html", "path_params" => path_params }),
          tool("api_write", { "endpoint" => "edit_#{surface}_custom_html", "path_params" => path_params, "params" => { "find" => original, "replace" => formatted } }),
          tool("complete_turn", { "outcome" => "proposal_ready" }),
        )
        post :create, params: @auth_params.merge(messages: [{ role: "user", content: "Bold the instruction on my #{surface} page." }]), as: :json
        expect(response).to be_successful, response.body
        first = response.parsed_body

        post :execute, params: @auth_params.merge(confirmation_for(first)), as: :json
        expect(response.parsed_body["success"]).to be(true), response.parsed_body.inspect
        expect(response.parsed_body).not_to have_key("html_undo")
        conversation = @seller.ai_conversations.sole
        applied_message = conversation.ai_messages.role_assistant.last
        expect(applied_message.reload.metadata.fetch("html_undo")).to be_present
        expect(applied_message.metadata.fetch("action_started_at")).to match(Ai::StoreAgentHtmlUndo::ACTION_STARTED_AT_FORMAT)

        allow(client).to receive(:messages).and_return(
          tool("prepare_html_undo", {}),
          tool("complete_turn", { "outcome" => "proposal_ready" }),
        )
        post :create, params: @auth_params.merge(
          conversation_id: conversation.external_id,
          messages: [{ role: "user", content: "Undo that formatting, keeping the instruction." }],
          html_undo: { "params" => { "find" => formatted, "replace" => "" } },
        ), as: :json
        expect(response).to be_successful, response.body
        [first, response.parsed_body, conversation]
      end

      it "proposes the exact inverse as a fresh one-shot confirmation without leaking the receipt" do
        pageable.update!(custom_html: original + '<a data-gumroad-action="buy">Buy</a>')
        original_page = pageable.reload.custom_html

        first, inverse, conversation = apply_formatting_and_prepare_undo
        formatted_page = pageable.reload.custom_html

        expect(inverse.fetch("proposed_action").dig("params", "params")).to include("find" => formatted, "replace" => original)
        expect(inverse.fetch("proposal_message_id")).not_to eq(first.fetch("proposal_message_id"))
        expect(pageable.reload.custom_html).to eq(formatted_page)
        # Hydration (the only reconciliation read installed apps perform) and the model transcript
        # carry proposal state only, never the receipt.
        hydrated = controller.send(:agent_conversation_props, conversation, hide_executing_action: true).to_json
        expect(hydrated).not_to include("html_undo", "action_started_at")
        expect(controller.send(:agent_conversation_history, conversation).to_json).not_to include("html_undo", "expected_custom_html_sha256", formatted)

        confirmation = confirmation_for(inverse)
        post :execute, params: @auth_params.merge(confirmation), as: :json
        expect(response.parsed_body["success"]).to be(true), response.parsed_body.inspect
        expect(response.parsed_body).not_to have_key("html_undo")
        expect(pageable.reload.custom_html).to eq(original_page)

        post :execute, params: @auth_params.merge(confirmation), as: :json
        expect(response.parsed_body["success"]).to be(false)
        expect(pageable.reload.custom_html).to eq(original_page)
      end

      it "refuses the prepared undo at confirmation once the page has changed underneath it" do
        pageable.update!(custom_html: original + '<a data-gumroad-action="buy">Buy</a>')

        _first, inverse, _conversation = apply_formatting_and_prepare_undo
        pageable.update!(custom_html: pageable.reload.custom_html + "<footer>Edited elsewhere</footer>")
        changed_page = pageable.reload.custom_html

        post :execute, params: @auth_params.merge(confirmation_for(inverse)), as: :json

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to include("changed")
        expect(pageable.reload.custom_html).to eq(changed_page)
      end
    end
  end
end
