# frozen_string_literal: true

# Ai::StoreAgentService powers the conversational "Agent" dashboard tab. The seller chats with an
# assistant that can answer questions about their store and *propose* changes to it.
#
# Safety model:
#   - READ tools (list_products, store_stats, list_discounts) run automatically and only ever query
#     data the seller already owns. They are scoped to current_seller, so the agent can never read
#     another seller's data.
#   - WRITE tools (create_discount, update_product_price, publish_product, unpublish_product) DO NOT
#     mutate anything here. They return a structured "proposed action" that the frontend renders as a
#     confirmation card. Nothing is applied until the seller explicitly confirms, at which point the
#     controller hands the action to Ai::StoreAgentActionExecutor. This keeps an LLM hallucination or
#     a prompt injection from silently changing a store.
#
# The loop is a standard OpenAI tool-calling exchange: we send the conversation + tool schemas, run
# any read tools the model asks for, feed the results back, and repeat until the model returns a
# normal assistant message (optionally carrying one proposed write action).
class Ai::StoreAgentService
  include CurrencyHelper

  class Error < StandardError; end

  MODEL = "gpt-4o-mini"
  REQUEST_TIMEOUT_IN_SECONDS = 60
  MAX_TOOL_ITERATIONS = 5
  MAX_MESSAGE_LENGTH = 2_000
  # How many prior turns of context we forward to the model. Keeps token usage bounded and avoids
  # echoing an unbounded client-supplied history back to OpenAI.
  MAX_HISTORY_MESSAGES = 20
  # Cap how many object cards we render inline per turn so a large list can't flood the chat.
  MAX_DISPLAY_OBJECTS = 20

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
      response = client.chat(
        parameters: {
          model: MODEL,
          messages: conversation,
          tools: tool_schemas,
          tool_choice: "auto",
          temperature: 0.3,
        },
      )

      message = response.dig("choices", 0, "message")
      raise Error, "No response from model" if message.nil?

      tool_calls = message["tool_calls"]
      if tool_calls.blank?
        return { reply: message["content"].to_s.strip, proposed_action: proposed_action&.as_json, objects: deduped_objects }
      end

      # Echo the assistant tool-call message back into the conversation before answering each call,
      # as required by the OpenAI tool-calling protocol.
      conversation << { role: "assistant", content: message["content"], tool_calls: }

      tool_calls.each do |tool_call|
        name = tool_call.dig("function", "name")
        arguments = parse_arguments(tool_call.dig("function", "arguments"))
        result, action = run_tool(name:, arguments:)
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
        conversation << {
          role: "tool",
          tool_call_id: tool_call["id"],
          name:,
          content: result.to_json,
        }
      end
    end

    # The model kept calling tools past our cap. Return whatever change it staged plus a message that
    # matches reality: only mention confirmation when there is actually a proposed action to confirm.
    reply =
      if proposed_action
        "I gathered the details but need you to confirm the next step before I continue."
      else
        "I gathered the details but couldn't finish in one go. Please rephrase or ask again."
      end
    { reply:, proposed_action: proposed_action&.as_json, objects: deduped_objects }
  end

  private
    attr_reader :seller, :pundit_user

    # De-duplicate the collected objects (the model may read the same list twice in one turn) while
    # preserving order, and cap how many cards we render so a huge list can't flood the chat.
    def deduped_objects
      Array(@objects).uniq.first(MAX_DISPLAY_OBJECTS)
    end

    def build_conversation(messages)
      history = Array(messages).last(MAX_HISTORY_MESSAGES).filter_map do |msg|
        role = msg[:role] || msg["role"]
        content = (msg[:content] || msg["content"]).to_s.strip
        next if content.blank?
        next unless %w[user assistant].include?(role)

        { role:, content: content.truncate(MAX_MESSAGE_LENGTH, omission: "...") }
      end
      raise Error, "Message is required" if history.empty? || history.last[:role] != "user"

      [{ role: "system", content: system_prompt }, *history]
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

    # Tool-call sub-objects are supposed to be JSON objects; a hallucinating model can emit an array
    # or scalar. Coerce anything that isn't a Hash to an empty hash, and stringify keys, so downstream
    # indexing/path-expansion can't raise a TypeError that surfaces as a 500.
    def sanitize_param_hash(raw)
      return {} unless raw.is_a?(Hash)
      raw.transform_keys(&:to_s)
    end

    def api_client
      @_api_client ||= Ai::StoreAgentApiClient.new(seller:)
    end

    # ---- helpers ----

    def parse_arguments(raw)
      return {} if raw.blank?
      # OpenAI tool-call arguments are *supposed* to be a JSON object, but a hallucinating model can
      # emit a bare array ("[1,2,3]") or scalar ("42"). The tools index arguments by key
      # (arguments["endpoint"]), which raises TypeError on an Array/Integer and would surface as an
      # unhandled 500. Coerce anything that isn't an object to an empty hash so the tool falls through
      # to its normal "field is required" validation instead.
      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def client
      @_client ||= OpenAI::Client.new(request_timeout: REQUEST_TIMEOUT_IN_SECONDS)
    end

    # Two generic tools. The endpoint id (constrained to the catalog by an enum) selects which of the
    # ~60 real API endpoints to hit; path_params/params carry the ids and payload. Keeping the JSON
    # schema this small avoids a 60-function tool list while still reaching the entire API.
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
        type: "function",
        function: {
          name:,
          description:,
          parameters: { type: "object", properties:, required:, additionalProperties: false },
        },
      }
    end
end
