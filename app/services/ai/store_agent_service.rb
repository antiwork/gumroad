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

  SYSTEM_PROMPT = <<~PROMPT.strip
    You are Gumroad's store assistant. You help a creator understand and manage their own Gumroad
    store through a chat interface in their dashboard.

    You can:
    - Answer questions about the creator's products, sales, payouts, and discounts using the read tools.
    - Propose changes to the store (create a discount code, change a product's price, publish or
      unpublish a product) using the write tools.

    Rules:
    - Only ever act on the current creator's own store. You cannot access other creators' data.
    - Read tools return live data; use them instead of guessing numbers.
    - Write tools NEVER take effect immediately. They produce a proposed change that the creator must
      review and confirm in the UI. Never claim a change has been made; say you've prepared it for
      their confirmation.
    - Propose at most one change per reply. If the creator asks for several changes, do the first and
      tell them you'll continue once they confirm.
    - Prices are in the product's own currency. Amounts you pass to tools are in whole currency units
      (dollars), not cents.
    - Be concise and concrete. Reference products by name.
  PROMPT

  ProposedAction = Struct.new(:type, :params, :summary, keyword_init: true) do
    def as_json(*) = { type:, params:, summary: }
  end

  def initialize(seller:, pundit_user:)
    @seller = seller
    @pundit_user = pundit_user
  end

  # @param messages [Array<Hash>] prior conversation, each { role: "user"|"assistant", content: String }
  # @return [Hash] { reply: String, proposed_action: Hash|nil }
  def respond(messages:)
    conversation = build_conversation(messages)
    proposed_action = nil

    MAX_TOOL_ITERATIONS.times do
      response = client.chat(parameters: {
        model: MODEL,
        messages: conversation,
        tools: tool_schemas,
        tool_choice: "auto",
        temperature: 0.3,
      })

      message = response.dig("choices", 0, "message")
      raise Error, "No response from model" if message.nil?

      tool_calls = message["tool_calls"]
      if tool_calls.blank?
        return { reply: message["content"].to_s.strip, proposed_action: proposed_action&.as_json }
      end

      # Echo the assistant tool-call message back into the conversation before answering each call,
      # as required by the OpenAI tool-calling protocol.
      conversation << { role: "assistant", content: message["content"], tool_calls: }

      tool_calls.each do |tool_call|
        name = tool_call.dig("function", "name")
        arguments = parse_arguments(tool_call.dig("function", "arguments"))
        result, action = run_tool(name:, arguments:)
        proposed_action = action if action.present?
        conversation << {
          role: "tool",
          tool_call_id: tool_call["id"],
          name:,
          content: result.to_json,
        }
      end
    end

    # The model kept calling tools past our cap. Return whatever change it staged plus a safe message.
    {
      reply: "I gathered the details but need you to confirm the next step before I continue.",
      proposed_action: proposed_action&.as_json,
    }
  end

  private
    attr_reader :seller, :pundit_user

    def build_conversation(messages)
      history = Array(messages).last(MAX_HISTORY_MESSAGES).filter_map do |msg|
        role = msg[:role] || msg["role"]
        content = (msg[:content] || msg["content"]).to_s.strip
        next if content.blank?
        next unless %w[user assistant].include?(role)

        { role:, content: content.truncate(MAX_MESSAGE_LENGTH, omission: "...") }
      end
      raise Error, "Message is required" if history.empty? || history.last[:role] != "user"

      [{ role: "system", content: SYSTEM_PROMPT }, *history]
    end

    def run_tool(name:, arguments:)
      case name
      when "list_products" then [tool_list_products, nil]
      when "store_stats" then [tool_store_stats, nil]
      when "list_discounts" then [tool_list_discounts, nil]
      when "create_discount" then propose_create_discount(arguments)
      when "update_product_price" then propose_update_product_price(arguments)
      when "publish_product" then propose_set_published(arguments, published: true)
      when "unpublish_product" then propose_set_published(arguments, published: false)
      else
        [{ error: "Unknown tool: #{name}" }, nil]
      end
    end

    # ---- Read tools (auto-executed, current_seller-scoped) ----

    def tool_list_products
      products = seller.products.visible_and_not_archived.order(created_at: :desc).limit(50).to_a
      sales_counts = cached_sales_counts_for(products)
      {
        products: products.map do |product|
          {
            id: product.external_id,
            name: product.name,
            price: format_amount(product.price_cents, product.price_currency_type),
            currency: product.price_currency_type,
            published: product.alive?,
            sales_count: sales_counts[product.id] || 0,
          }
        end,
      }
    end

    # Read each product's sales count from its most recent ProductCachedValue row in two queries,
    # instead of running a per-product Elasticsearch count (which would be a 50x N+1).
    def cached_sales_counts_for(products)
      return {} if products.empty?

      latest_ids = ProductCachedValue.where(product_id: products.map(&:id)).group(:product_id).maximum(:id).values
      return {} if latest_ids.empty?

      ProductCachedValue.where(id: latest_ids).pluck(:product_id, :successful_sales_count).to_h
    end

    def tool_store_stats
      stats = {
        total_products: seller.products.visible_and_not_archived.count,
        published_products: seller.products.alive.count,
        gross_sales: format_amount(seller.sales_cents_total, seller.currency_type),
        currency: seller.currency_type,
      }
      # Payout/balance data is gated by the SAME policy as the Payouts page (BalancePolicy#index?),
      # which excludes roles like marketing. Only expose the unpaid balance to roles that can already
      # see it through the dashboard, so the agent can't become a side channel around that policy.
      if can_view_balance?
        stats[:unpaid_balance] = format_amount(seller.unpaid_balance_cents, seller.currency_type)
      end
      stats
    end

    def can_view_balance?
      Pundit.policy!(pundit_user, :balance).index?
    end

    def tool_list_discounts
      offer_codes = seller.offer_codes.alive.order(created_at: :desc).limit(50)
      {
        discounts: offer_codes.map do |offer_code|
          {
            id: offer_code.external_id,
            code: offer_code.code,
            amount: offer_code.is_percent? ? "#{offer_code.amount_percentage}%" : format_amount(offer_code.amount_cents, seller.currency_type),
            universal: offer_code.universal?,
          }
        end,
      }
    end

    # ---- Write tools (return a proposed action; never mutate) ----

    def propose_create_discount(arguments)
      code = arguments["code"].to_s.strip
      percent_off = arguments["percent_off"]
      amount_off = arguments["amount_off"]

      if code.blank?
        return [{ error: "A discount code is required." }, nil]
      end
      if percent_off.blank? && amount_off.blank?
        return [{ error: "Provide either percent_off or amount_off." }, nil]
      end

      summary =
        if percent_off.present?
          "Create discount code #{code} for #{percent_off.to_i}% off (applies to all products)."
        else
          "Create discount code #{code} for #{format_amount(string_to_price_cents(seller.currency_type, amount_off.to_s), seller.currency_type)} off (applies to all products)."
        end

      action = ProposedAction.new(
        type: "create_discount",
        params: { code:, percent_off: percent_off.presence&.to_i, amount_off_cents: amount_off.present? ? string_to_price_cents(seller.currency_type, amount_off.to_s) : nil }.compact,
        summary:,
      )
      [{ proposed: true, summary: }, action]
    end

    def propose_update_product_price(arguments)
      product = find_product(arguments["product_id"])
      return [{ error: "I couldn't find that product." }, nil] if product.nil?
      # Tiered memberships and variant-priced products keep the buyer-visible price on their
      # tiers/variants, not the product's own price_cents column — changing price_cents there would
      # silently no-op the displayed price. Refuse rather than report a misleading success.
      if priced_by_variants?(product)
        return [{ error: "\"#{product.name}\" is priced per tier/version, so I can't change its price from here. Edit it on the product page." }, nil]
      end

      new_price = arguments["new_price"]
      return [{ error: "A new price is required." }, nil] if new_price.blank?

      new_price_cents = string_to_price_cents(product.price_currency_type, new_price.to_s)
      summary = "Change the price of \"#{product.name}\" from " \
                "#{format_amount(product.price_cents, product.price_currency_type)} to " \
                "#{format_amount(new_price_cents, product.price_currency_type)}."
      action = ProposedAction.new(
        type: "update_product_price",
        params: { product_id: product.external_id, new_price_cents: },
        summary:,
      )
      [{ proposed: true, summary: }, action]
    end

    def propose_set_published(arguments, published:)
      product = find_product(arguments["product_id"])
      return [{ error: "I couldn't find that product." }, nil] if product.nil?

      verb = published ? "Publish" : "Unpublish"
      summary = "#{verb} \"#{product.name}\"."
      action = ProposedAction.new(
        type: published ? "publish_product" : "unpublish_product",
        params: { product_id: product.external_id },
        summary:,
      )
      [{ proposed: true, summary: }, action]
    end

    # ---- helpers ----

    def find_product(external_id)
      return nil if external_id.blank?
      seller.products.visible.find_by_external_id(external_id.to_s)
    end

    # True when the buyer-visible price lives on tiers/variants rather than the product's own
    # price_cents column, so a flat price_cents change wouldn't affect what buyers actually pay.
    def priced_by_variants?(product)
      product.is_tiered_membership? || product.alive_variants.exists?
    end

    def format_amount(cents, currency_type)
      MoneyFormatter.format(cents.to_i, (currency_type || "usd").to_sym, symbol: true, no_cents_if_whole: false)
    end

    def parse_arguments(raw)
      return {} if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    def client
      @_client ||= OpenAI::Client.new(request_timeout: REQUEST_TIMEOUT_IN_SECONDS)
    end

    def tool_schemas
      [
        tool_schema("list_products", "List the creator's products with price, currency, publish status, and sales count.", {}),
        tool_schema("store_stats", "Get high-level store stats: product counts, gross sales, and unpaid balance.", {}),
        tool_schema("list_discounts", "List the creator's active discount codes.", {}),
        tool_schema(
          "create_discount",
          "Propose creating a universal discount code that applies to all products. Provide exactly one of percent_off or amount_off.",
          {
            code: { type: "string", description: "The discount code, e.g. SUMMER25." },
            percent_off: { type: "integer", description: "Percentage off, 1-100." },
            amount_off: { type: "number", description: "Fixed amount off in whole currency units (dollars)." },
          },
          required: ["code"],
        ),
        tool_schema(
          "update_product_price",
          "Propose changing a product's price.",
          {
            product_id: { type: "string", description: "The product id from list_products." },
            new_price: { type: "number", description: "The new price in whole currency units (dollars)." },
          },
          required: %w[product_id new_price],
        ),
        tool_schema("publish_product", "Propose publishing a product so it becomes available for sale.", { product_id: { type: "string", description: "The product id from list_products." } }, required: ["product_id"]),
        tool_schema("unpublish_product", "Propose unpublishing a product so it is no longer available for sale.", { product_id: { type: "string", description: "The product id from list_products." } }, required: ["product_id"]),
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
