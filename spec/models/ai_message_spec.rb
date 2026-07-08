# frozen_string_literal: true

require "spec_helper"

describe AiMessage do
  describe "validations" do
    it "requires a known role" do
      message = build(:ai_message, role: "user")
      expect(message).to be_valid

      # The enum is declared with validate: true, so an unknown role makes the record invalid
      # instead of raising on assignment.
      message.role = "system"
      expect(message).not_to be_valid
      expect(message.errors[:role]).to be_present
    end

    it "defaults content to an empty string so tokenless assistant turns persist" do
      message = create(:ai_message, role: "assistant", content: nil)
      expect(message.content).to eq("")
    end
  end

  it "touches the conversation so recency ordering follows activity" do
    conversation = create(:ai_conversation, updated_at: 1.day.ago)
    expect { create(:ai_message, ai_conversation: conversation) }.to change { conversation.reload.updated_at }
  end

  it "round-trips structured metadata (proposal payloads, objects)" do
    metadata = { "proposed_action" => { "type" => "api_write", "summary" => "Create a discount" }, "action_status" => "applied" }
    message = create(:ai_message, role: "assistant", metadata:)
    expect(message.reload.metadata).to eq(metadata)
  end
end
