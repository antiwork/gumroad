# frozen_string_literal: true

require "spec_helper"

describe AiConversation do
  describe "associations" do
    it "orders messages by insertion and destroys them with the conversation" do
      conversation = create(:ai_conversation)
      # Same created_at second on purpose: ordering must fall back to id (insertion order) so two
      # turns saved in the same second still replay in the order they happened.
      now = Time.current.change(usec: 0)
      travel_to(now) do
        create(:ai_message, ai_conversation: conversation, content: "Question")
        create(:ai_message, ai_conversation: conversation, role: "assistant", content: "Reply")
      end

      expect(conversation.ai_messages.reload.map(&:content)).to eq(["Question", "Reply"])

      expect { conversation.destroy! }.to change(AiMessage, :count).by(-2)
    end
  end

  describe "Deletable" do
    it "soft deletes via mark_deleted! and drops out of the alive scope" do
      conversation = create(:ai_conversation)
      expect { conversation.mark_deleted! }.to change { described_class.alive.count }.by(-1)
      expect(described_class.count).to eq(1)
    end
  end

  describe ".title_from" do
    it "derives a truncated single-line title from the first user message" do
      expect(described_class.title_from("  How are my sales?  ")).to eq("How are my sales?")
      expect(described_class.title_from("a" * 200).length).to eq(described_class::TITLE_MAX_LENGTH)
      expect(described_class.title_from("   ")).to be_nil
    end
  end
end
