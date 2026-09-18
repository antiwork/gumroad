# frozen_string_literal: true

class Ai::StoreAgentHtmlUndo
  ENDPOINTS = %w[edit_user_custom_html edit_product_custom_html].freeze
  # What the claim's DATE_FORMAT(CURRENT_TIMESTAMP(6), ...) writes (AgentConversationPersistence).
  # Only a marker in this shape is CAST back to a datetime; anything else fails closed.
  ACTION_STARTED_AT_FORMAT = /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}\z/
  RESOLVED_STATUSES = %w[applied unknown].freeze

  # Execution intervals, not finalization order, identify the last applied change across targets.
  # Overlapping or still-running actions make the inverse ambiguous, so refuse rather than guess.
  def self.latest_for(seller:, conversation:)
    return unless conversation

    messages = AiMessage.role_assistant.joins(:ai_conversation)
      .where(ai_conversations: { id: conversation.id, seller_id: seller.id, deleted_at: nil })
    claimed = messages.where("JSON_EXTRACT(ai_messages.metadata, '$.action_status') IS NOT NULL")
    return if claimed.where("ai_messages.metadata->>'$.action_status' NOT IN (?)", RESOLVED_STATUSES).exists?

    candidate = claimed.where("ai_messages.metadata->>'$.action_status' = ?", "applied")
      .reorder(updated_at: :desc, id: :desc).first
    return unless candidate

    started_at = candidate.metadata["action_started_at"]
    return unless started_at.is_a?(String) && started_at.match?(ACTION_STARTED_AT_FORMAT)
    # A claim that finished before it started is corrupt bookkeeping, not evidence.
    return unless claimed.where(id: candidate.id).where("ai_messages.updated_at >= CAST(? AS DATETIME(6))", started_at).exists?
    return if claimed.where.not(id: candidate.id).where("ai_messages.updated_at >= CAST(? AS DATETIME(6))", started_at).exists?

    receipt = candidate.metadata["html_undo"]
    return unless receipt.is_a?(Hash) && ENDPOINTS.include?(receipt["endpoint"])
    return unless receipt["path_params"].is_a?(Hash) && receipt["params"].is_a?(Hash)
    return unless receipt["params"].keys.sort == %w[expected_custom_html_sha256 find replace result_custom_html_sha256]
    return unless receipt["params"].values.all? { |value| value.is_a?(String) && value.present? }

    receipt.deep_dup
  end

  # Only retain an inverse when the actual saved page is exactly the requested splice.
  # Whole-document sanitization can otherwise change content outside the edited snippet.
  def self.receipt(endpoint:, path_params:, body:, response:)
    return unless ENDPOINTS.include?(endpoint) && response["success"] == true

    before_html = response["previous_custom_html"]
    after_html = response["custom_html"]
    find, replace = body.values_at("find", "replace")
    return unless [before_html, after_html, find, replace].all? { |value| value.is_a?(String) && value.present? }
    return if before_html == after_html || after_html.scan(replace).size != 1

    match = Ai::CustomHtmlSnippetMatcher.match(before_html, find)
    return unless match.occurrences == 1 && before_html.sub(match.matcher) { replace } == after_html
    return unless after_html.sub(replace) { before_html[match.matcher] } == before_html

    {
      "endpoint" => endpoint,
      "path_params" => path_params,
      "params" => {
        "find" => replace,
        "replace" => before_html[match.matcher],
        "expected_custom_html_sha256" => Digest::SHA256.hexdigest(after_html),
        "result_custom_html_sha256" => Digest::SHA256.hexdigest(before_html),
      },
    }
  end
end
