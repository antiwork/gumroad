# frozen_string_literal: true

require "spec_helper"

describe Ai::StoreAgentHtmlUndo do
  describe ".latest_for" do
    let(:seller) { create(:user) }
    let(:conversation) { create(:ai_conversation, seller:) }
    let(:receipt) do
      { "endpoint" => "edit_user_custom_html", "path_params" => {}, "params" => {
        "find" => "<strong>Original</strong>", "replace" => "Original",
        "expected_custom_html_sha256" => "a" * 64, "result_custom_html_sha256" => "b" * 64,
      } }
    end
    let(:product_receipt) { receipt.merge("endpoint" => "edit_product_custom_html", "path_params" => { "id" => "synthetic-product" }) }
    let(:now) { Time.current }
    let!(:applied) { claimed_row("applied", started_at: now - 5.minutes, finished_at: now - 4.minutes, html_undo: receipt) }

    # The claim SQL writes DATE_FORMAT(CURRENT_TIMESTAMP(6), '%Y-%m-%d %H:%i:%s.%f'); mirror it byte for byte.
    def db_marker(time) = time.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")

    def claimed_row(status, started_at:, finished_at:, html_undo: nil, marker: :from_start)
      marker = db_marker(started_at) if marker == :from_start
      conversation.ai_messages.create!(
        role: "assistant",
        content: "Old confirmation copy",
        metadata: { action_status: status, action_started_at: marker, html_undo: }.compact,
        updated_at: finished_at,
      )
    end

    it "returns the receipt of a finalized change whose interval nothing else overlaps" do
      expect(described_class.latest_for(seller:, conversation:)).to eq(receipt)
    end

    it "selects by execution order, so a proposal created earlier but applied later wins" do
      # `applied` (created first) ran 5→4 minutes ago; this later-created row ran 3→2 minutes ago.
      claimed_row("applied", started_at: now - 3.minutes, finished_at: now - 2.minutes, html_undo: product_receipt)
      expect(described_class.latest_for(seller:, conversation:)).to eq(product_receipt)
    end

    it "selects a change created later but applied earlier over one applied afterwards" do
      applied.update_columns(metadata: applied.metadata.merge("action_started_at" => db_marker(now - 1.minute)), updated_at: now - 30.seconds)
      claimed_row("applied", started_at: now - 3.minutes, finished_at: now - 2.minutes, html_undo: product_receipt)
      expect(described_class.latest_for(seller:, conversation:)).to eq(receipt)
    end

    it "refuses overlapping confirmations even when their edits target different pages" do
      # A profile edit claimed first but finalized last, with a product edit run entirely inside it.
      applied.update_columns(metadata: applied.metadata.merge("action_started_at" => db_marker(now - 3.minutes)), updated_at: now)
      claimed_row("applied", started_at: now - 2.minutes, finished_at: now - 1.minute, html_undo: product_receipt)
      expect(described_class.latest_for(seller:, conversation:)).to be_nil
    end

    it "ignores pending proposals created after the applied change" do
      conversation.ai_messages.create!(role: "assistant", metadata: { proposed_action: { type: "api_write" } })
      conversation.ai_messages.create!(role: "assistant", content: "A reply with no proposal")
      expect(described_class.latest_for(seller:, conversation:)).to eq(receipt)
    end

    it "does not skip a more recently applied unsupported change" do
      claimed_row("applied", started_at: now - 3.minutes, finished_at: now - 2.minutes)
      expect(described_class.latest_for(seller:, conversation:)).to be_nil
    end

    it "ignores an unknown outcome that demonstrably finished before the candidate started" do
      claimed_row("unknown", started_at: now - 20.minutes, finished_at: now - 10.minutes)
      expect(described_class.latest_for(seller:, conversation:)).to eq(receipt)
    end

    it "refuses an unknown outcome whose finish overlaps the candidate's interval" do
      claimed_row("unknown", started_at: now - 6.minutes, finished_at: now - 4.minutes - 30.seconds)
      expect(described_class.latest_for(seller:, conversation:)).to be_nil
    end

    it "refuses while any action is executing, even one older than the candidate" do
      claimed_row("executing", started_at: now - 1.hour, finished_at: now - 1.hour)
      expect(described_class.latest_for(seller:, conversation:)).to be_nil
    end

    it "refuses an unrecognized status regardless of age" do
      claimed_row("invalid", started_at: now - 1.hour, finished_at: now - 1.hour)
      expect(described_class.latest_for(seller:, conversation:)).to be_nil
    end

    [nil, "", "1758124235.532", "2026-09-17T15:50:35Z", "2026-09-17 15:50:35", "not a time"].each do |marker|
      it "fails closed on missing or malformed start marker #{marker.inspect}" do
        applied.update_columns(metadata: applied.metadata.merge("action_started_at" => marker).compact)
        expect(described_class.latest_for(seller:, conversation:)).to be_nil
      end
    end

    it "fails closed when the start marker is later than the finalization" do
      applied.update_columns(metadata: applied.metadata.merge("action_started_at" => db_marker(now - 3.minutes)))
      expect(described_class.latest_for(seller:, conversation:)).to be_nil
    end

    it "never reads another seller's conversation" do
      expect(described_class.latest_for(seller: create(:user), conversation:)).to be_nil
    end

    it "never falls back to a different conversation" do
      expect(described_class.latest_for(seller:, conversation: create(:ai_conversation, seller:))).to be_nil
      expect(described_class.latest_for(seller:, conversation: nil)).to be_nil
    end

    it "refuses a deleted conversation even if the caller holds an old instance" do
      conversation.update!(deleted_at: Time.current)
      expect(described_class.latest_for(seller:, conversation:)).to be_nil
    end

    [nil, {}, { "endpoint" => "delete_product" }, { "endpoint" => "edit_user_custom_html", "params" => [] }].each do |malformed|
      it "refuses malformed receipt #{malformed.inspect}" do
        applied.update_columns(metadata: applied.metadata.merge("html_undo" => malformed))
        expect(described_class.latest_for(seller:, conversation:)).to be_nil
      end
    end
  end

  describe ".receipt" do
    [
      ["<p>Original</p>", "", ""],
      ["<p>Original</p>", "<p>Original</p>", "<p>Original</p>"],
      ["<p>Original</p>", "<script>unsafe()</script>", ""],
      ["<p>Original</p><b>New</b>", "<b>New</b>", "<b>New</b><b>New</b>"],
      ["<p>Original</p>", "<b>New</b>", "<b>New</b><footer>Unexpected</footer>"],
    ].each_with_index do |(before_html, replace, after_html), index|
      it "refuses non-reversible saved transformation #{index}" do
        expect(described_class.receipt(endpoint: "edit_user_custom_html", path_params: {},
                                       body: { "find" => "<p>Original</p>", "replace" => replace },
                                       response: { "success" => true, "previous_custom_html" => before_html, "custom_html" => after_html })).to be_nil
      end
    end

    it "refuses an inverse whose overlapping replacement selects a different occurrence" do
      expect(described_class.receipt(
        endpoint: "edit_user_custom_html", path_params: {},
        body: { "find" => "<b>aa</b>", "replace" => "aa" },
        response: { "success" => true, "previous_custom_html" => "<p>a<b>aa</b></p>", "custom_html" => "<p>aaa</p>" },
      )).to be_nil
    end

    it "records the actual original snippet and both page digests after a reversible formatting edit" do
      before_html = "<p>Keep this instruction.</p><footer>Unchanged</footer>"
      after_html = "<p><strong>Keep this instruction.</strong></p><footer>Unchanged</footer>"
      receipt = described_class.receipt(
        endpoint: "edit_product_custom_html",
        path_params: { "id" => "synthetic-product" },
        body: { "find" => "<p>Keep this instruction.</p>", "replace" => "<p><strong>Keep this instruction.</strong></p>" },
        response: { "success" => true, "previous_custom_html" => before_html, "custom_html" => after_html },
      )

      expect(receipt).to eq(
        "endpoint" => "edit_product_custom_html", "path_params" => { "id" => "synthetic-product" },
        "params" => {
          "find" => "<p><strong>Keep this instruction.</strong></p>", "replace" => "<p>Keep this instruction.</p>",
          "expected_custom_html_sha256" => Digest::SHA256.hexdigest(after_html),
          "result_custom_html_sha256" => Digest::SHA256.hexdigest(before_html),
        },
      )
    end
  end
end
