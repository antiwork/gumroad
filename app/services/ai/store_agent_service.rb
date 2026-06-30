# frozen_string_literal: true

# Ai::StoreAgentService powers the conversational "Agent" dashboard tab. The seller chats with an
# assistant that can answer questions about their store and *propose* changes to it.
#
# The agent runs on Anthropic's Claude Opus 4.7 (via Ai::AnthropicClient). Opus 4.7 currently leads
# the vending-bench leaderboard for autonomous commercial operation, so it is the strongest model
# for the agent's actual job: helping a creator run and grow their store.
#
# Safety model:
#   - READ tools (api_read) run automatically and only ever query data the seller already owns. They
#     are scoped to current_seller, so the agent can never read another seller's data.
#   - WRITE tools (api_write) DO NOT mutate anything here. They return a structured "proposed action"
#     that the frontend renders as a confirmation card. Nothing is applied until the seller explicitly
#     confirms, at which point the controller hands the action to Ai::StoreAgentActionExecutor. This
#     keeps an LLM hallucination or a prompt injection from silently changing a store.
#
# The loop is a standard Anthropic tool-use exchange: we send the system prompt + conversation + tool
# schemas, run any read tools the model asks for, feed the results back as tool_result blocks, and
# repeat until the model returns a normal assistant message (optionally carrying one proposed write).
class Ai::StoreAgentService
  include CurrencyHelper

  class Error < StandardError; end

  MODEL = Ai::AnthropicClient::DEFAULT_MODEL
  REQUEST_TIMEOUT_IN_SECONDS = 60
  MAX_TOOL_ITERATIONS = 5
  MAX_MESSAGE_LENGTH = 2_000
  # Anthropic requires max_tokens; size it for a brief chat reply plus a tool call's JSON args.
  MAX_REPLY_TOKENS = 1_500
  # How many prior turns of context we forward to the model. Keeps token usage bounded and avoids
  # echoing an unbounded client-supplied history back to the model.
  MAX_HISTORY_MESSAGES = 20
  # Cap how many object cards we render inline per turn so a large list can't flood the chat.
  MAX_DISPLAY_OBJECTS = 20
  # How many "what next" follow-up prompts we suggest at the end of a turn to keep the conversation
  # going, and the max length of each so a chip stays a tappable phrase, not a paragraph.
  MAX_SUGGESTIONS = 3
  SUGGESTION_MAX_LENGTH = 80
  MAX_SUGGESTION_TOKENS = 200

  # A tiny separate completion turns the just-finished exchange into a few natural next prompts the
  # creator is likely to want, phrased in their own voice so they read as one-tap continuations.
  FOLLOW_UP_PROMPT = <<~PROMPT.strip
    You suggest what a Gumroad creator might want to ask their store assistant NEXT, to keep the
    conversation going. Given the creator's last message and the assistant's answer, return up to
    three short follow-up prompts.

    Rules:
    - Phrase each as something the CREATOR would say to the assistant, in the first person
      (e.g. "Show my best sellers this month", "Email my customers about it").
    - Keep each under 8 words. No numbering, no quotes, no trailing punctuation.
    - Make them specific and relevant to what was just discussed and to running a store.
    - Return ONLY a JSON array of strings, nothing else. If nothing useful fits, return [].
  PROMPT

  # The system prompt is assembled at runtime (see #system_prompt) so it can embed the live catalog
  # manifest of every endpoint the agent can reach. This keeps the prompt and the actual tool surface
  # from drifting apart as endpoints are added to the catalog.
  SYSTEM_PROMPT_HEADER = <<~PROMPT.strip
    You are Gumroad's store assistant. You help a creator understand and manage their own Gumroad
    store through a chat interface in their dashboard.

    You have two tools that together expose the creator's ENTIRE Gumroad API:
    - api_read: run any READ endpoint to fetch live data (products, sales, payouts, discounts,
      subscribers, upsells, emails, tax forms, earnings, profile, and more). These run immediately.
    - api_write: prepare any change (create/update/delete products, discounts, variants, upsells,
      emails, refunds, shipping, licenses, webhooks, profile, and more). Writes never take effect
      immediately — they produce a proposed change the creator reviews and confirms in the UI.

    To call a tool you pass `endpoint` (one of the ids listed below), `path_params` (the ids the
    endpoint's path needs, e.g. the product id), and `params` (query for reads, body for writes).

    How to act:
    - Be helpful and proactive. If the creator describes a change they want, go ahead and prepare it
      for them with api_write so it's ready to confirm — don't just explain how they could do it
      themselves. Offer to make the change.
    - Only ever act on the current creator's own store. You cannot access other creators' data; the
      API enforces this and an endpoint the creator's role can't use will simply fail.
    - Always use api_read to get real ids and live numbers before acting. Never invent ids.
    - Never claim a change has already been made. After api_write, tell the creator you've prepared it
      and it's ready for them to confirm.
    - Prepare at most one change per reply. If the creator asks for several, do the first and tell
      them you'll continue once they confirm.
    - Monetary amounts in the API are in CENTS (integer). $10 = 1000.

    How to write:
    - Write like a person: warm, plain, and direct. Short sentences. No corporate filler.
    - Do not use emoji.
    - Do not use markdown headers, bold, bullet characters, tables, or other decorative formatting.
      Just write normal sentences. Products, discounts, and other objects you look up or change are
      shown to the creator automatically as cards beneath your message, so don't re-list their
      details or paste links in the text — refer to them by name and keep your reply brief.
    - Don't mention other people, teammates, or @-handles.

    READ endpoints (api_read):
    %<reads>s

    WRITE endpoints (api_write — each requires confirmation):
    %<writes>s
  PROMPT

  ProposedAction = Struct.new(:type, :params, :summary, keyword_init: true) do
    def as_json(*) = { type:, params:, summary: }
  end

  def initialize(seller:, pundit_user:)
    @seller = seller
    @pundit_user = pundit_user
  end

  # @param messages [Array<Hash>] prior conversation, each { role: "user"|"assistant", content: String }
  # @return [Hash] { reply: String, proposed_action: Hash|nil, objects: Array<Hash> }
  def respond(messages:)
    conversation = build_conversation(messages)
    proposed_action = nil
    # Display objects collected from the read calls this turn, rendered inline as cards in the chat.
    @objects = []

    MAX_TOOL_ITERATIONS.times do
      result = client.messages(
        system: system_prompt,
        messages: conversation,
        tools: tool_schemas,
        max_tokens: MAX_REPLY_TOKENS,
      )

      if result.tool_uses.blank?
        return { reply: result.text.to_s.strip, proposed_action: proposed_action&.as_json, objects: deduped_objects }
      end

      proposed_action = apply_tool_uses(text: result.text, tool_uses: result.tool_uses, conversation:, proposed_action:)
    end

    { reply: tool_cap_reply(proposed_action), proposed_action: proposed_action&.as_json, objects: deduped_objects }
  end

  # Streaming counterpart of #respond. Runs the same read/propose tool loop, but streams the final
  # assistant reply token-by-token and, once the answer is complete, suggests a few follow-up prompts
  # to keep the conversation going. Communicates by yielding [event, payload] pairs the controller
  # writes to the client as Server-Sent Events:
  #   [:token, { text: }]                 — a chunk of the reply text, as it arrives
  #   [:objects, { objects: }]            — object cards looked up/changed this turn
  #   [:proposed_action, { proposed_action: }] — a single staged change awaiting confirmation
  #   [:suggestions, { suggestions: }]    — up to three "what next" prompts
  # Returns the same hash shape as #respond (plus :suggestions) once the stream is complete.
  def respond_streaming(messages:, &emit)
    conversation = build_conversation(messages)
    last_user_message = conversation.reverse.find { |m| m[:role] == "user" }&.dig(:content).to_s
    proposed_action = nil
    @objects = []

    MAX_TOOL_ITERATIONS.times do
      # Stream this turn's text deltas live. We don't yet know if the turn is final (text-only) or an
      # intermediate tool-use turn that happens to include preamble text, so track whether anything
      # was streamed: if the turn turns out to be a tool-use turn, we emit :reset to discard its
      # preamble from the UI, and only the final (tool_uses-blank) turn's text survives on screen.
      streamed_any = false
      result = client.stream_messages(
        system: system_prompt,
        messages: conversation,
        tools: tool_schemas,
        max_tokens: MAX_REPLY_TOKENS,
      ) do |text|
        streamed_any = true
        emit.call(:token, { text: })
      end

      if result.tool_uses.blank?
        reply = result.text.to_s.strip
        return finish_stream(reply:, proposed_action:, last_user_message:, emit:)
      end

      # Intermediate tool-use turn: any text it streamed was preamble, not the answer. Tell the UI to
      # clear it so the seller never sees an interim claim that gets replaced by the real reply.
      emit.call(:reset, {}) if streamed_any
      proposed_action = apply_tool_uses(text: result.text, tool_uses: result.tool_uses, conversation:, proposed_action:)
    end

    # Hit the tool-iteration cap. Stream the fallback line as a single token so the UI still renders a
    # reply, then close out with the same objects/action/suggestions as a normal turn.
    reply = tool_cap_reply(proposed_action)
    emit.call(:token, { text: reply })
    finish_stream(reply:, proposed_action:, last_user_message:, emit:)
  end

  private
    attr_reader :seller, :pundit_user

    # Echo the assistant's tool-use turn back into the conversation, run each requested tool, and
    # append a single user message carrying the tool_result blocks (the Anthropic tool-use protocol).
    # Returns the (possibly updated) proposed action. Shared by #respond and #respond_streaming so the
    # two paths can't drift.
    def apply_tool_uses(text:, tool_uses:, conversation:, proposed_action:)
      # The assistant turn must replay both any text it produced AND the tool_use blocks, in order.
      assistant_content = []
      assistant_content << { type: "text", text: text.to_s } if text.to_s.strip.present?
      tool_uses.each do |tool_use|
        assistant_content << { type: "tool_use", id: tool_use[:id], name: tool_use[:name], input: tool_use[:input] || {} }
      end
      conversation << { role: "assistant", content: assistant_content }

      tool_results = tool_uses.map do |tool_use|
        arguments = sanitize_param_hash(tool_use[:input])
        result, action = run_tool(name: tool_use[:name], arguments:)
        if action.present?
          if proposed_action.nil?
            proposed_action = action
          else
            # Only one change may be staged per turn. If the model proposes a second write in the
            # same turn we drop it and tell the model, so the confirmation card can never describe a
            # different mutation than the one the seller sees and confirms.
            result = { error: "Only one change can be proposed at a time. Ask the seller to confirm the first change before proposing another." }
          end
        end
        { type: "tool_result", tool_use_id: tool_use[:id], content: result.to_json }
      end
      conversation << { role: "user", content: tool_results }

      proposed_action
    end

    # The model kept calling tools past our cap. Return a message that matches reality: only mention
    # confirmation when there is actually a proposed action to confirm.
    def tool_cap_reply(proposed_action)
      if proposed_action
        "I gathered the details but need you to confirm the next step before I continue."
      else
        "I gathered the details but couldn't finish in one go. Please rephrase or ask again."
      end
    end

    # Emit the trailing events for a completed streaming turn (objects, any staged change, and the
    # follow-up suggestions) and return the full result hash.
    def finish_stream(reply:, proposed_action:, last_user_message:, emit:)
      objects = deduped_objects
      emit.call(:objects, { objects: }) if objects.any?
      emit.call(:proposed_action, { proposed_action: proposed_action.as_json }) if proposed_action
      suggestions = follow_up_suggestions(reply:, last_user_message:)
      emit.call(:suggestions, { suggestions: }) if suggestions.any?
      { reply:, proposed_action: proposed_action&.as_json, objects:, suggestions: }
    end

    # Ask the model for a few short, in-voice next prompts based on the turn that just happened. Kept
    # deliberately cheap (no tools, low max_tokens) and fully best-effort: any failure or unparseable
    # output yields no suggestions rather than breaking the reply the creator already received.
    def follow_up_suggestions(reply:, last_user_message:)
      return [] if reply.blank?

      result = client.messages(
        system: FOLLOW_UP_PROMPT,
        messages: [
          { role: "user", content: "The creator said: #{last_user_message}\n\nYou answered: #{reply}\n\nSuggest up to three follow-up prompts." },
        ],
        max_tokens: MAX_SUGGESTION_TOKENS,
      )
      parse_suggestions(result.text)
    rescue => e
      Rails.logger.warn("Store agent follow-up suggestions failed: #{e.message}")
      []
    end

    # Coerce the model's reply into a clean list of suggestion strings. Prefers a JSON array but
    # tolerates a newline/dash list, then trims, de-dupes, drops blanks, and caps count + length.
    def parse_suggestions(raw)
      text = raw.to_s.strip
      return [] if text.blank?

      parsed = (JSON.parse(text) rescue nil)
      items =
        if parsed.is_a?(Array)
          parsed
        else
          text.split("\n").map { |line| line.sub(/\A\s*(?:[-*\d.)\s]+)/, "") }
        end

      items
        .map { |item| item.to_s.strip.delete_prefix('"').delete_suffix('"').strip }
        .reject(&:blank?)
        .map { |item| item.truncate(SUGGESTION_MAX_LENGTH) }
        .uniq
        .first(MAX_SUGGESTIONS)
    end

    # De-duplicate the collected objects (the model may read the same list twice in one turn) while
    # preserving order, and cap how many cards we render so a huge list can't flood the chat.
    def deduped_objects
      Array(@objects).uniq.first(MAX_DISPLAY_OBJECTS)
    end

    # Build the Anthropic message array from the client-supplied history. The system prompt is passed
    # separately (Anthropic's top-level `system` param), so it is NOT included here.
    def build_conversation(messages)
      history = Array(messages).last(MAX_HISTORY_MESSAGES).filter_map do |msg|
        role = msg[:role] || msg["role"]
        content = (msg[:content] || msg["content"]).to_s.strip
        next if content.blank?
        next unless %w[user assistant].include?(role)

        { role:, content: content.truncate(MAX_MESSAGE_LENGTH, omission: "...") }
      end

      # Anthropic's Messages API requires the conversation to START with a user message. The web chat
      # always opens with a canned assistant greeting (and a turn could begin with other leading
      # assistant turns), so drop any leading assistant messages before the first user message.
      history = history.drop_while { |m| m[:role] != "user" }
      raise Error, "Message is required" if history.empty? || history.last[:role] != "user"

      history
    end

    # Assemble the system prompt with the live read/write endpoint manifests embedded, so the model
    # is told exactly which endpoint ids exist and what each does.
    def system_prompt
      format(
        SYSTEM_PROMPT_HEADER,
        reads: Ai::StoreAgentApiCatalog.manifest(:read),
        writes: Ai::StoreAgentApiCatalog.manifest(:write),
      )
    end

    # Two generic tools drive the whole catalog. `api_read` runs a read endpoint immediately;
    # `api_write` turns a write endpoint into a single proposed action (never mutates here).
    def run_tool(name:, arguments:)
      case name
      when "api_read" then run_api_read(arguments)
      when "api_write" then propose_api_write(arguments)
      else
        [{ error: "Unknown tool: #{name}" }, nil]
      end
    end

    # ---- api_read: auto-executed, creator-scoped via the real v2 API ----

    def run_api_read(arguments)
      endpoint = Ai::StoreAgentApiCatalog.find(arguments["endpoint"])
      if endpoint.nil?
        return [{ error: "Unknown endpoint. Use one of the read endpoint ids listed for api_read." }, nil]
      end
      unless endpoint.read?
        # A write id was sent to the read tool. Don't run it (that would mutate without confirmation);
        # tell the model to use api_write so it goes through the confirmation card.
        return [{ error: "#{endpoint.id} changes data — use api_write so the creator can confirm it." }, nil]
      end
      unless endpoint_permitted?(endpoint)
        # Defense in depth: the minted token's scopes already exclude this, so the API would 403, but
        # refusing here avoids a wasted dispatch and gives the model a clear reason.
        return [{ error: "The current user's role can't access #{endpoint.id}." }, nil]
      end

      path = endpoint.expand_path(arguments["path_params"])
      result = api_client.get(path, sanitize_param_hash(arguments["params"]))
      # Collect any renderable objects from the response so the chat can show them inline as cards.
      @objects.concat(Ai::StoreAgentObjectFormatter.from_response(endpoint, result)) if @objects
      [result, nil]
    rescue ArgumentError => e
      # Missing/blank path param (e.g. the model forgot the product id).
      [{ error: e.message }, nil]
    end

    # ---- api_write: returns a proposed action; never mutates ----

    def propose_api_write(arguments)
      endpoint = Ai::StoreAgentApiCatalog.find(arguments["endpoint"])
      if endpoint.nil?
        return [{ error: "Unknown endpoint. Use one of the write endpoint ids listed for api_write." }, nil]
      end
      unless endpoint.write?
        # A read id was sent to the write tool. Reads never need confirmation; nudge the model to use
        # api_read instead so it gets the data immediately.
        return [{ error: "#{endpoint.id} only reads data — use api_read to get it immediately." }, nil]
      end
      unless endpoint_permitted?(endpoint)
        # Defense in depth: don't even stage a proposal the acting user's role can't execute, so the
        # seller never sees a confirmation card for a change that would 403 on confirm.
        return [{ error: "The current user's role can't perform #{endpoint.id}." }, nil]
      end

      path_params = sanitize_param_hash(arguments["path_params"])
      body = sanitize_param_hash(arguments["params"])
      # Validate the path can actually be built now (so the confirmation card never describes a call
      # that would fail on a missing id at execute time).
      begin
        endpoint.expand_path(path_params)
      rescue ArgumentError => e
        return [{ error: e.message }, nil]
      end

      summary = write_summary(endpoint, path_params, body)
      action = ProposedAction.new(
        type: "api_write",
        # Everything the executor needs to replay the exact same call after the creator confirms.
        params: { "endpoint" => endpoint.id, "path_params" => path_params, "params" => body },
        summary:,
      )
      [{ proposed: true, summary: }, action]
    end

    # A human-readable description of the pending change for the confirmation card. Built from the
    # catalog summary plus the concrete ids/params so the creator sees exactly what will happen.
    def write_summary(endpoint, path_params, body)
      parts = [endpoint.summary]
      detail = path_params.merge(body).map { |k, v| "#{k}: #{v}" }.join(", ")
      parts << "(#{detail})" if detail.present?
      parts.join(" ")
    end

    # Tool-call inputs are supposed to be JSON objects; a hallucinating model can emit an array or
    # scalar (or, for a nested key, a non-hash). Coerce anything that isn't a Hash to an empty hash,
    # and stringify keys, so downstream indexing/path-expansion can't raise a TypeError as a 500.
    def sanitize_param_hash(raw)
      return {} unless raw.is_a?(Hash)
      raw.transform_keys(&:to_s)
    end

    def api_client
      @_api_client ||= Ai::StoreAgentApiClient.new(seller:, pundit_user:)
    end

    # True if the acting user's role may drive this endpoint. Requires the role to carry the
    # endpoint's scope AND, for endpoints the dashboard restricts to admins beyond their OAuth scope
    # (admin_only?, e.g. webhook management), the acting user to be an owner/admin. Mirrors the token
    # narrowing so a read/proposal the API or our role boundary would refuse is rejected up front.
    def endpoint_permitted?(endpoint)
      return false if endpoint.admin_only? && !admin_or_owner?
      endpoint.scope.blank? || permitted_scopes.include?(endpoint.scope)
    end

    def admin_or_owner?
      user = pundit_user&.user
      seller = pundit_user&.seller
      user.present? && seller.present? && user.role_admin_for?(seller)
    end

    def permitted_scopes
      @_permitted_scopes ||= Ai::StoreAgentScopes.permitted_for(pundit_user)
    end

    def client
      @_client ||= Ai::AnthropicClient.new(timeout: REQUEST_TIMEOUT_IN_SECONDS, model: MODEL)
    end

    # Two generic tools. The endpoint id (constrained to the catalog by an enum) selects which of the
    # ~60 real API endpoints to hit; path_params/params carry the ids and payload. Keeping the schema
    # this small avoids a 60-function tool list while still reaching the entire API. Anthropic tool
    # schemas use `input_schema` (JSON Schema) instead of OpenAI's `function.parameters`.
    def tool_schemas
      [
        tool_schema(
          "api_read",
          "Read live data from the creator's Gumroad store by calling a READ API endpoint. Runs immediately.",
          {
            endpoint: { type: "string", enum: Ai::StoreAgentApiCatalog.read_ids, description: "Which read endpoint to call (see the READ endpoints list)." },
            path_params: { type: "object", description: "Ids the endpoint's path needs, e.g. {\"id\": \"<product id>\"}. Omit if none.", additionalProperties: { type: "string" } },
            params: { type: "object", description: "Query parameters, e.g. {\"after\": \"2024-01-01\"}. Omit if none." },
          },
          required: ["endpoint"],
        ),
        tool_schema(
          "api_write",
          "PROPOSE a change to the creator's store by calling a WRITE API endpoint. Does NOT take effect until the creator confirms. Propose only one change per reply.",
          {
            endpoint: { type: "string", enum: Ai::StoreAgentApiCatalog.write_ids, description: "Which write endpoint to call (see the WRITE endpoints list)." },
            path_params: { type: "object", description: "Ids the endpoint's path needs, e.g. {\"id\": \"<product id>\"}. Omit if none.", additionalProperties: { type: "string" } },
            params: { type: "object", description: "Request body. Monetary amounts are in cents (integer). Omit if none." },
          },
          required: ["endpoint"],
        ),
      ]
    end

    def tool_schema(name, description, properties, required: [])
      {
        name:,
        description:,
        input_schema: { type: "object", properties:, required: },
      }
    end
end
