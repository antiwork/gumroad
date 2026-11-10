# frozen_string_literal: true

module Mcp
  # JSON-RPC MCP surface shared by every connector path (/muse, /claude, /chatgpt).
  # Tools are a slim, agent-oriented view of the public v2 API — same auth, same records.
  class Server
    LEGACY_PROTOCOL_VERSION = "2025-03-26"
    # Characters simple_query_string treats as operators: a query made only of these matches
    # everything, which is not something an assistant should be able to ask for.
    QUERY_OPERATOR_CHARACTERS = /[+\-=&|><!(){}\[\]^"~*?:\\\/]/
    SEARCH_QUERY_MAX_LENGTH = 200
    SEARCH_DEFAULT_LIMIT = 10
    SEARCH_MAX_LIMIT = 25
    # A client on this revision declares its version per request and never handshakes.
    MODERN_PROTOCOL_VERSION = "2026-07-28"
    SUPPORTED_VERSIONS = [LEGACY_PROTOCOL_VERSION, MODERN_PROTOCOL_VERSION].freeze
    VERSION_HEADER = "MCP-Protocol-Version"
    METHOD_HEADER = "Mcp-Method"
    NAME_HEADER = "Mcp-Name"
    VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion"
    SERVER_INFO_META_KEY = "io.modelcontextprotocol/serverInfo"
    # Reserved for the modern transport; the legacy -32000..-32019 sub-range is not extended.
    HEADER_MISMATCH = -32020
    UNSUPPORTED_PROTOCOL_VERSION = -32022
    TRANSPORT_ERROR_CODES = [HEADER_MISMATCH, UNSUPPORTED_PROTOCOL_VERSION].freeze
    # Most tools answer for the caller's own store, so no result of ours is shareable between callers.
    TOOLS_LIST_CACHE = { ttlMs: 0, cacheScope: "private" }.freeze
    # Its versions follow a flag, so it is never fresh.
    DISCOVER_CACHE = { ttlMs: 0, cacheScope: "public" }.freeze
    # Mcp::Events follows ChatGPT's draft of the extension, which another client would misread.
    EVENTS_CONNECTOR = "chatgpt"
    INSTRUCTIONS = "Use these tools for a connected creator's own store: products, sales, and payouts. search_products also searches the rest of Gumroad's catalogue. Confirm with the person before publishing or unpublishing. Buyers still check out on the product URL. This server does not take payment."
    DEFAULT_BUNDLE_MEMBER_QUANTITY = 1
    SERVER_INFO = { name: "gumroad", title: "Gumroad", version: "1.0.0" }.freeze
    PRODUCT_TYPES = %w[digital membership].freeze
    TIER_KEYS = %w[name price_cents recurrence].freeze
    TIER_PRICING_KEYS = %w[pay_what_you_want suggested_price_cents].freeze
    # The product editor's currency list (config/currencies.json). Link#price_currency_type= only
    # downcases what it is given, so the tools check the list themselves — in any case, since a
    # caller writes "USD" as readily as "usd".
    CURRENCIES = CURRENCY_CHOICES.keys.map(&:to_s).freeze
    # The editor's tag picker: up to ten tags of two to twenty characters each.
    MAX_TAGS = 10
    MIN_TAG_LENGTH = 2
    MAX_TAG_LENGTH = 20
    MICROSECONDS_PER_SECOND = 1_000_000
    # The last year MySQL DATETIME holds; a bound outside 0..this year fails in SQL instead of as a bad argument.
    MAX_DATETIME_YEAR = 9999

    class Error < StandardError
      attr_reader :code, :data

      def initialize(message, code: -32000, data: nil)
        super(message)
        @code = code
        @data = data
      end
    end

    ANALYTICS_BREAKDOWNS = %w[product referrer].freeze
    ANALYTICS_DEFAULT_DAYS = 30
    ANALYTICS_MAX_DAYS = 366
    ANALYTICS_MAX_REFERRERS = 50
    SUBSCRIPTION_BREAKDOWNS = %w[subscriptions churn].freeze
    SUBSCRIPTION_STATUSES = %w[alive ended].freeze
    SUBSCRIPTION_CHURN_DEFAULT_MONTHS = 11
    # Churn buckets by day in Elasticsearch, so the range carries the same cost ceiling as analytics.
    SUBSCRIPTION_CHURN_MAX_DAYS = 366

    CUSTOMER_BREAKDOWNS = %w[spend conversion].freeze
    CUSTOMERS_DEFAULT_ROWS = 25
    # Rack::Timeout ends the request at 120s, so a query this slow needs its own deadline to report.
    CUSTOMERS_QUERY_TIMEOUT = 30
    CUSTOMER_REFUNDED = "COALESCE(purchases.stripe_refunded, 0) = 1"
    CUSTOMER_FREE = "COALESCE(purchases.price_cents, 0) = 0"
    TOTALS_BREAKDOWNS = %w[product country day week month].freeze
    # An unknown category answers with the likeliest few; the whole tree is too long for an error.
    MAX_CATEGORY_SUGGESTIONS = 10
    TOTALS_DEFAULT_DAYS = 30
    TOTALS_MAX_DAYS = 366
    # A store can have thousands of products, and there are ~250 countries; period rows are bounded by the range.
    TOTALS_MAX_ROWS = 100

    class ToolError < StandardError; end

    DISCOUNT_PERCENT_RANGE = (1..100)
    # DATETIME's range: MySQL, outside strict mode, stores a later year as a zero date that reads back as nil.
    DISCOUNT_YEAR_RANGE = (1000..9999)
    DISCOUNT_MIN_VALIDITY_WINDOW = 1.second
    DISCOUNT_CODE_FIELDS = {
      "percent_off" => { type: "integer", description: "Percent off, #{DISCOUNT_PERCENT_RANGE.min}-#{DISCOUNT_PERCENT_RANGE.max}. Not with amount_cents." },
      "amount_cents" => { type: "integer", description: "Fixed amount off in minor units of the product's currency (the creator's currency for an all-products code). Not with percent_off." },
      "valid_at" => { type: "string", description: "ISO 8601 time the code starts working. If only expires_at is given, the start is now for a new code and unchanged for an existing one." },
      "expires_at" => { type: "string", description: "ISO 8601 time the code stops working." },
      "max_purchase_count" => { type: "integer", description: "How many times the code can be used in total. 0 or more." }
    }.freeze

    # A scope check failed where no step-up is possible - a batch, or a client that registered none
    # of the accepted scopes. The caller gets the same plain error as before; the counter still
    # records it as lost scope rather than as a tool failure.
    class MissingScope < Error; end

    # The caller's arguments do not fit the tool's schema. Counted apart from a tool failure,
    # because the fix is on the client side and it would otherwise inflate the error rate.
    class InvalidArguments < Error; end

    # A tool's scope check failed. `scope` is what the client should re-authorize with: the
    # scopes the token already holds plus the missing one, so the step-up keeps the old grant.
    class InsufficientScope < Error
      attr_reader :scope

      def initialize(message, scope:)
        super(message)
        @scope = scope
      end
    end

    def initialize(user:, token:, connector: nil, protocol_version_header: nil, method_header: nil, name_header: nil)
      @user = user
      @token = token
      @connector = connector
      @protocol_version_header = protocol_version_header
      @method_header = method_header
      @name_header = name_header
      # Per-request tool counters, flushed with the protocol counters in `handle`'s ensure.
      @tool_counts = Hash.new(0)
      @era = :legacy
    end

    # The era the request resolved to, for callers that must pick a transport-level status.
    # A batch stays modern once any message in it declared that revision.
    attr_reader :era
    # The scope failure of this request, if any, for the controller's RFC 6750 challenge. The
    # JSON-RPC body keeps the plain -32000 error that legacy clients already handle.
    attr_reader :insufficient_scope

    def handle(body)
      @protocol_counts = Hash.new(0)
      if body.is_a?(Array)
        return rpc_error(nil, "Invalid Request", code: -32600) if body.empty?

        # A client retries the whole request after a step-up, which would repeat any message in
        # the batch that already ran. A batch keeps its per-message errors and gets no challenge.
        @batch = true
        return body.filter_map { |message| handle_message(message) }.presence
      end

      handle_message(body)
    ensure
      # One stalled Redis costs the request one short timeout, not two: the tool counter rides the
      # same connection, so a failed protocol write means the tool write would only stall again.
      ProtocolTelemetry.record_tools(@connector, @tool_counts) if ProtocolTelemetry.record(@connector, @protocol_counts)
    end

    def self.discovery(base_url)
      {
        name: "Gumroad",
        description: "Sell digital products. An MCP client can list products and sales, draft and edit a product, add the files and links buyers receive and a cover image, publish it, and check payouts for a connected creator.",
        website: "https://gumroad.com",
        documentation: "#{base_url}/muse",
        mcp: "#{base_url}/muse/v1/mcp",
        clients: {
          muse: "#{base_url}/muse/v1/mcp",
          claude: "#{base_url}/claude/v1/mcp",
          chatgpt: "#{base_url}/chatgpt/v1/mcp",
          cursor: "#{base_url}/cursor/v1/mcp",
          antigravity: "#{base_url}/antigravity/v1/mcp"
        },
        oauth: {
          authorization_endpoint: "#{base_url}/muse/v1/oauth2/authorize",
          token_endpoint: "#{base_url}/muse/v1/oauth2/token",
          registration_endpoint: "#{base_url}/muse/v1/oauth2/register",
          scopes: OauthClientRegistration::MCP_SCOPES
        },
        api: "#{base_url}/api"
      }
    end

    def self.oauth_metadata(base_url)
      {
        issuer: base_url,
        authorization_endpoint: "#{base_url}/muse/v1/oauth2/authorize",
        token_endpoint: "#{base_url}/muse/v1/oauth2/token",
        registration_endpoint: "#{base_url}/muse/v1/oauth2/register",
        response_types_supported: ["code"],
        grant_types_supported: %w[authorization_code refresh_token],
        token_endpoint_auth_methods_supported: %w[none client_secret_post client_secret_basic],
        scopes_supported: OauthClientRegistration::MCP_SCOPES,
        code_challenge_methods_supported: %w[S256 plain]
      }
    end

    def self.protected_resource_metadata(base_url, resource_path: "/muse/v1/mcp")
      {
        resource: "#{base_url}#{resource_path}",
        authorization_servers: [base_url],
        bearer_methods_supported: ["header"],
        scopes_supported: OauthClientRegistration::MCP_SCOPES
      }
    end

    private
      attr_reader :user, :token

      def handle_message(body)
        return rpc_error(nil, "Invalid Request", code: -32600) unless body.is_a?(Hash)

        id = valid_id?(body["id"]) ? body["id"] : nil
        # A version error is a transport error and is answered even for a notification: the
        # caller cannot act on a request whose era was never established.
        resolve_era!(body)
        return rpc_error(id, "Invalid Request", code: -32600) unless body["jsonrpc"] == "2.0"
        # We issue no server requests; unsolicited client replies need no dispatch or response.
        return nil if client_response?(body)
        unless body["method"].is_a?(String) && (!body.key?("id") || valid_id?(body["id"])) && !body.key?("result") && !body.key?("error")
          return rpc_error(id, "Invalid Request", code: -32600)
        end

        notification = !body.key?("id")
        method = body["method"]
        params = body.fetch("params", {})
        raise Error.new("params must be an object", code: -32602) unless params.is_a?(Hash)
        validate_modern_transport!(method, params)

        result = dispatch(method, params)
        notification ? nil : envelope(id, result)
      rescue Error => e
        # A transport error is the caller's only signal that nothing was dispatched.
        return rpc_error(id, e.message, code: e.code, data: e.data) if TRANSPORT_ERROR_CODES.include?(e.code)

        notification ? nil : rpc_error(id, e.message, code: e.code, data: e.data)
      end

      # Era is per request: an undeclared request is legacy and keeps its exact current path.
      # The 2026-07-28 schema declares the version in `params._meta`; a top-level `_meta`, which this
      # endpoint read first, is still honoured. The header is checked against the declaration. A
      # legacy client sends neither, so a header alone stays legacy rather than becoming an era error.
      def resolve_era!(body)
        nested = declared_version(body["params"])
        top_level = declared_version(body)
        declared = nested || top_level
        # Counted before the checks below, so a client that has already moved to a revision we do
        # not serve yet still shows up in the mix.
        @protocol_counts[ProtocolTelemetry.bucket(declared, body["method"])] += 1
        return if declared.nil?

        if nested && top_level && nested.to_s != top_level.to_s
          raise Error.new(
            "_meta #{VERSION_META_KEY} must not differ between params and the request",
            code: HEADER_MISMATCH,
            data: { declared: nested, top_level: top_level }
          )
        end

        header = @protocol_version_header.presence
        if header.nil? || declared.to_s != header.to_s
          raise Error.new(
            "#{VERSION_HEADER} and _meta #{VERSION_META_KEY} must agree",
            code: HEADER_MISMATCH,
            data: { header: header, declared: declared }
          )
        end

        supported = supported_versions
        unless supported.include?(declared.to_s)
          raise Error.new(
            "Unsupported protocol version: #{declared}",
            code: UNSUPPORTED_PROTOCOL_VERSION,
            data: { supported: supported, requested: declared }
          )
        end

        @era = :modern if declared.to_s == MODERN_PROTOCOL_VERSION
      end

      def declared_version(container)
        meta = container.is_a?(Hash) ? container["_meta"] : nil
        meta.is_a?(Hash) ? meta[VERSION_META_KEY].presence : nil
      end

      # The modern lane ships behind a flag: with it off, 2026-07-28 is not supported yet.
      def supported_versions
        return SUPPORTED_VERSIONS if Feature.active?(:mcp_protocol_2026_07_28)

        [LEGACY_PROTOCOL_VERSION]
      end

      def validate_modern_transport!(method, params)
        return unless era == :modern

        if @method_header.presence != method
          raise Error.new(
            "#{METHOD_HEADER} must repeat the request method",
            code: HEADER_MISMATCH,
            data: { header: @method_header, method: method }
          )
        end
        return unless method == "tools/call"

        name = params["name"]
        if @name_header.blank? || @name_header != name
          raise Error.new(
            "#{NAME_HEADER} must repeat the tool name",
            code: HEADER_MISMATCH,
            data: { header: @name_header, name: name }
          )
        end
      end

      # This revision removed the handshake and ping: a modern client starts at server/discover.
      def dispatch(method, params)
        # Either revision: ChatGPT handshakes without one and declares it on later calls.
        if Events::METHODS.include?(method) && events_enabled?
          # Each first subscribe can wait seconds on a challenge, and a batch has no size limit.
          raise Error.new("Send events/subscribe on its own, not in a batch.", code: -32600) if @batch && method == "events/subscribe"

          return events.call(method, params)
        end

        if era == :modern
          case method
          when "server/discover" then discover_result
          when "tools/list" then { tools: tools, **TOOLS_LIST_CACHE }
          when "tools/call" then call_tool(params)
          else raise Error.new("Method not found: #{method}", code: -32601)
          end
        else
          case method
          when "initialize" then initialize_result
          when "notifications/initialized", "notifications/cancelled" then nil
          when "ping" then {}
          when "tools/list" then { tools: tools }
          when "tools/call" then call_tool(params)
          else raise Error.new("Method not found: #{method}", code: -32601)
          end
        end
      end

      def envelope(id, result)
        result = result.merge(resultType: "complete") if era == :modern && result.is_a?(Hash)
        { jsonrpc: "2.0", id:, result: }
      end

      def discover_result
        {
          supportedVersions: supported_versions,
          capabilities:,
          _meta: { SERVER_INFO_META_KEY => SERVER_INFO },
          instructions: INSTRUCTIONS,
          # The events capability follows a per-seller flag, so a result that carries it is the caller's own.
          **(events_enabled? ? DISCOVER_CACHE.merge(cacheScope: "private") : DISCOVER_CACHE)
        }
      end

      def capabilities
        capabilities = { tools: { listChanged: false } }
        # Top-level, where ChatGPT reads it: see Mcp::Events.
        capabilities[:events] = {} if events_enabled?
        capabilities
      end

      def events_enabled?
        return @events_enabled if defined?(@events_enabled)

        @events_enabled = @connector == EVENTS_CONNECTOR && token&.application_id.present? && Feature.active?(:mcp_events, user)
      end

      def events
        @events ||= Events.new(
          user:,
          token:,
          authorize_sales: -> { require_scopes!(*McpEventSubscription::SCOPES, subject: "Subscribing to an event") },
          validate_arguments: method(:validate_tool_arguments!)
        )
      end

      def valid_id?(id)
        id.is_a?(String) || id.is_a?(Integer)
      end

      def client_response?(body)
        return false if body.key?("method") || body.key?("params") || !valid_id?(body["id"])
        return false unless body.key?("result") ^ body.key?("error")
        return body["result"].is_a?(Hash) if body.key?("result")

        error = body["error"]
        error.is_a?(Hash) && error["code"].is_a?(Integer) && error["message"].is_a?(String)
      end

      def initialize_result
        {
          protocolVersion: LEGACY_PROTOCOL_VERSION,
          capabilities:,
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS
        }
      end

      def tools
        [
          tool("get_account", "The connected creator's public profile: name, username, storefront URL, currency.", {}, read_only: true),
          tool("list_products", "List the creator's products (newest first). Returns id, name, price, published state, whether it is a bundle, and URL.", {
                 "limit" => { type: "integer", description: "Max products to return (1-50, default 25)." },
                 "cursor" => { type: "string", description: "next_cursor from the previous page." }
               }, read_only: true),
          tool("get_product", "Fetch one product by id or permalink, with its category, description, summary, additional details, tags, covers, receipt message and button text, and the products a bundle sells. The first cover is the main one.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id], read_only: true),
          tool("list_categories", "Every product category, as a slug path joined by / with the name the product editor shows. update_product takes one of these paths as its category; the category decides where the product appears in Discover.", {}, read_only: true),
          tool("create_draft_product", "Create a draft digital product, or a draft membership with tiers billed on a recurring period. It is not for sale until publish_product runs. Confirm the name and prices with the creator first.", {
                 "name" => { type: "string", description: "Product name." },
                 "price_cents" => { type: "integer", description: "Price in minor units (cents for USD). Use 0 for a free product. Required for a digital product; not accepted for a membership, whose prices are set on its tiers." },
                 "currency" => { type: "string", description: "Currency to price the product in, spelled as the product editor's list does it, e.g. usd, eur or jpy. Defaults to the creator's own currency. price_cents, and every tier's price_cents, are in this currency." },
                 "pay_what_you_want" => { type: "boolean", description: "Whether buyers may pay more than price_cents, which stays the minimum. Not accepted for a membership; set it on each tier." },
                 "suggested_price_cents" => { type: "integer", description: "The amount the price box suggests to buyers when pay what you want is on, in minor units. Must be at least price_cents. Needs pay_what_you_want true in the same call." },
                 "description" => { type: "string", description: "HTML or plain-text description." },
                 "product_type" => { type: "string", enum: PRODUCT_TYPES, description: "digital (default) or membership." },
                 "tiers" => {
                   type: "array",
                   minItems: 1,
                   description: "Membership tiers, in display order. Required for a membership, not accepted otherwise. Every tier must use the same recurrence.",
                   items: {
                     type: "object",
                     properties: {
                       "name" => { type: "string", description: "Tier name." },
                       "price_cents" => { type: "integer", description: "Price per billing period in minor units of the product's currency. 0 makes the tier pay what you want." },
                       "pay_what_you_want" => { type: "boolean", description: "Whether buyers may pay more than this tier's price_cents, which stays the minimum." },
                       "suggested_price_cents" => { type: "integer", description: "The amount this tier's price box suggests to buyers, in minor units. Must be at least the tier's price_cents. Needs pay_what_you_want true on the same tier." },
                       "recurrence" => { type: "string", enum: BasePrice::Recurrence::ALLOWED_RECURRENCES, description: "Billing period." }
                     },
                     required: TIER_KEYS,
                     additionalProperties: false
                   }
                 }
               }, required: %w[name]),
          tool("update_product", "Change the name, description, summary, additional details, category, tags, price, currency, pay-what-you-want amount, URL, receipt message, or receipt button text of an existing product. Pass only the fields to change. The new description replaces the old one. Confirm the changes with the creator first.", {
                 "id" => { type: "string", description: "Product id or permalink." },
                 "name" => { type: "string", description: "New product name." },
                 "category" => { type: "string", description: "Category slug path from the list_categories result, e.g. 3d/3d-assets/blender. \"other\" means not categorised." },
                 "description" => { type: "string", description: "New HTML or plain-text description." },
                 "summary" => { type: "string", description: "New summary: the short plain-text line under the buy button on the product page. Send an empty string to remove it." },
                 "additional_details" => {
                   type: "array",
                   description: "The name and value rows the product page shows in the card with the summary, e.g. \"Pages: 40\", in the order to show them. This replaces the whole list; send an empty array to remove every row.",
                   items: {
                     type: "object",
                     properties: {
                       "name" => { type: "string", description: "Row label, e.g. \"Pages\"." },
                       "value" => { type: "string", description: "Row value, e.g. \"40\"." }
                     }
                   }
                 },
                 "tags" => {
                   type: "array",
                   description: "The tags Discover matches the product to shoppers by, e.g. \"field-notes\". Up to ten, two to twenty characters each. This replaces the whole list; send an empty array to remove every tag.",
                   items: { type: "string" }
                 },
                 "price_cents" => { type: "integer", description: "New price in minor units of the product's currency. Not available for memberships with tiers." },
                 "currency" => { type: "string", description: "Currency to re-denominate the product in. The current price, and the rental price of a product that has one, carry across at the same number, so pass price_cents too when the amount should change with it. Not available for a membership with tiers or a product sold on several payment options." },
                 "pay_what_you_want" => { type: "boolean", description: "Whether buyers may pay more than the price, which stays the minimum. Not available for memberships with tiers, whose tiers carry their own switch; a product priced 0 stays pay what you want." },
                 "suggested_price_cents" => { type: "integer", description: "The amount the price box suggests to buyers when pay what you want is on, in minor units of the product's currency. Must be at least the price. Needs pay what you want to be on, from this call or already." },
                 "custom_receipt_text" => { type: "string", description: "The message the buyer sees on the receipt, up to #{Product::Validations::MAX_CUSTOM_RECEIPT_TEXT_LENGTH} characters. Send an empty string to remove it." },
                 "custom_view_content_button_text" => { type: "string", description: "The text on the receipt's button that opens the product, up to #{Product::Validations::MAX_VIEW_CONTENT_BUTTON_TEXT_LENGTH} characters. Send an empty string to remove it." },
                 "permalink" => { type: "string", description: "New URL slug, the part after /l/. Letters, numbers, dashes, and underscores only. The old URL keeps working. Send an empty string to go back to the default URL." }
               }, required: %w[id], destructive: true),
          tool("add_cover", "Add a cover image or video to a product from a public URL. The first cover is the main one on the product page.", {
                 "id" => { type: "string", description: "Product id or permalink." },
                 "url" => { type: "string", description: "Public https URL of an image, or a YouTube or Vimeo link." }
               }, required: %w[id url]),
          tool("list_files", "The files a buyer receives with this product: name, type, size, and position. The download page lists them in this order.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id], read_only: true),
          tool("add_file", "Add a file that buyers receive with the product. Pass a public https url for a file the creator already has; ask for the link if they have not given one. Pass content and a filename only for text the creator is writing with you here (markdown, text, csv, json, ics, srt or vtt), which needs no hosting. Never stand in text you wrote for a file the creator owns. Files up to #{Mcp::ProductFileIngest::MAX_BYTES / 1.megabyte} MB from a URL, #{Mcp::ProductFileIngest::INLINE_MAX_BYTES / 1.megabyte} MB from content; larger files, like a long video, must be uploaded in the product editor.", {
                 "id" => { type: "string", description: "Product id or permalink." },
                 "url" => { type: "string", description: "Public https URL of the file. Omit when passing content." },
                 "content" => { type: "string", description: "The file's full text, written here rather than uploaded. Omit when passing url." },
                 "filename" => { type: "string", description: "File name with an extension, used for content, like field-notes.md. Ignored with url." },
                 "display_name" => { type: "string", description: "Name shown to the buyer. Defaults to the name in the URL, or the filename." }
               }, required: %w[id]),
          tool("add_content_link", "Add a button with a link to a product's content page, which the buyer opens after purchase. Use it when the product is delivered as a link, like a Notion template's duplication link. Confirm the link and the button text with the creator first.", {
                 "id" => { type: "string", description: "Product id or permalink." },
                 "url" => { type: "string", description: "The link the buyer opens. https is assumed when the value has no scheme." },
                 "label" => { type: "string", description: "Text on the button. Defaults to the URL." }
               }, required: %w[id url]),
          tool("publish_product", "Make a draft product purchasable. Confirm with the creator first.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id], destructive: true),
          tool("unpublish_product", "Take a product off sale without deleting it.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id], destructive: true),
          tool("list_sales", "Successful sales, newest first, with net amount, fees, country, discount code, affiliate commission, referrer and UTM fields. Free downloads count as sales; use payment=paid to skip them. When next_cursor is returned, pass it as cursor for the next page.", {
                 "limit" => { type: "integer", description: "Max sales to return (1-50, default 25)." },
                 "cursor" => { type: "string", description: "next_cursor from the previous page." },
                 "email" => { type: "string", description: "Filter by buyer email." },
                 "product_id" => { type: "string", description: "Only sales of this product (id from list_products)." },
                 "after" => { type: "string", description: "Only sales on or after this date or ISO 8601 time (UTC), e.g. 2026-10-01." },
                 "before" => { type: "string", description: "Only sales before this date or ISO 8601 time (UTC), e.g. 2026-11-01." },
                 "payment" => { type: "string", enum: %w[paid free], description: "paid = price above zero, free = zero-price sales." },
                 "kind" => { type: "string", enum: %w[subscription one_time], description: "subscription = membership charges, one_time = everything else." }
               }, read_only: true),
          tool("get_analytics", "Product page views, sales and revenue for a date range, so conversion rate (sales / views) can be computed. breakdown=product (default) gives one row per product; breakdown=referrer gives views, sales and revenue per traffic source. Revenue is price minus refunds and chargebacks, before fees, in minor units of USD. Dates are in the creator's time zone and default to the last 30 days.", {
                 "start_date" => { type: "string", description: "First day, YYYY-MM-DD. Defaults to 29 days before end_date." },
                 "end_date" => { type: "string", description: "Last day, YYYY-MM-DD. Defaults to today." },
                 "product_id" => { type: "string", description: "Only this product (id from list_products)." },
                 "breakdown" => { type: "string", enum: ANALYTICS_BREAKDOWNS, description: "product (default) or referrer." }
               }, read_only: true),
          tool("get_customers", "Buyer-level sales for the creator's store, one row per buyer email. breakdown=spend (default) gives orders count, spend, refunded and charged-back amounts, and first and last order dates per buyer; breakdown=conversion gives buyers whose first purchase was free and who later paid, with days to convert. Amounts are price before fees in minor units of USD, with refunds and chargebacks reported on their own lines; start_date and end_date are days in the creator's time zone that bound order dates, or the purchase that converted.", {
                 "breakdown" => { type: "string", enum: CUSTOMER_BREAKDOWNS, description: "spend (default) or conversion." },
                 "email" => { type: "string", description: "Only this buyer's email." },
                 "start_date" => { type: "string", description: "First day, YYYY-MM-DD, in the creator's time zone. Omit for all time." },
                 "end_date" => { type: "string", description: "Last day, YYYY-MM-DD, inclusive. Omit for all time." },
                 "limit" => { type: "integer", description: "Max buyers to return (1-50, default #{CUSTOMERS_DEFAULT_ROWS})." }
               }, read_only: true),
          tool("get_sales_totals", "Revenue, units and average order value for a date range, grouped by product, country or period. Counts sales that still stand: successful or preorder-authorized sales not refunded or charged back, free downloads included. Revenue is price before fees, in minor units of USD, and average_order_value_cents is revenue_cents divided by units. Dates are in the creator's time zone and default to the last 30 days. Product and country rows are the top 100 by revenue.", {
                 "start_date" => { type: "string", description: "First day, YYYY-MM-DD. Defaults to 29 days before end_date." },
                 "end_date" => { type: "string", description: "Last day, YYYY-MM-DD. Defaults to today." },
                 "product_id" => { type: "string", description: "Only this product (id from list_products)." },
                 "breakdown" => { type: "string", enum: TOTALS_BREAKDOWNS, description: "product (default), country, day, week or month. A period row's date is the day, the Monday of the week, or the first of the month, in the creator's time zone." }
               }, read_only: true),
          tool("get_subscriptions", "The creator's memberships and their state. breakdown=subscriptions (default) gives one row per subscription, newest first, with status, start date, cancel date and failed payments; breakdown=churn gives one row per month with the subscriber base, the subscribers who left and the churn rate, from the same source as the dashboard. Test subscriptions are excluded. Subscription timestamps are in UTC; churn dates are in the creator's time zone.", {
                 "breakdown" => { type: "string", enum: SUBSCRIPTION_BREAKDOWNS, description: "subscriptions (default) or churn." },
                 "limit" => { type: "integer", description: "Max subscriptions to return (1-50, default 25). breakdown=subscriptions only." },
                 "cursor" => { type: "string", description: "next_cursor from the previous page. breakdown=subscriptions only." },
                 "status" => { type: "string", enum: SUBSCRIPTION_STATUSES, description: "alive = still delivering content, including subscriptions set to cancel at the end of the period; ended = it has stopped (cancelled, failed, deactivated or its period ended). Omit for both. breakdown=subscriptions only." },
                 "product_id" => { type: "string", description: "Only this product (id from list_products)." },
                 "start_date" => { type: "string", description: "First day, YYYY-MM-DD. Defaults to the start of the month 11 months before end_date. breakdown=churn only." },
                 "end_date" => { type: "string", description: "Last day, YYYY-MM-DD. Defaults to today. breakdown=churn only." }
               }, read_only: true),
          tool("list_payouts", "Recent payouts to the creator's bank or PayPal.", {
                 "limit" => { type: "integer", description: "Max payouts to return (1-50, default 10)." },
                 "cursor" => { type: "string", description: "next_cursor from the previous page." }
               }, read_only: true),
          tool("search_products", "Search Gumroad's catalogue, not just the connected creator's own products. These are the same results the discover page shows. Use it when someone wants to see what exists in a topic, compare prices, or find something to learn a skill from. Each URL carries the MCP referrer, so a visit or purchase that starts from this result is distinguishable from the creator's own traffic.", {
                 "query" => { type: "string", description: "What to search for, e.g. \"learn to draw\" or \"tax spreadsheet\"." },
                 "limit" => { type: "integer", description: "Max products to return (1-#{SEARCH_MAX_LIMIT}, default #{SEARCH_DEFAULT_LIMIT})." }
               }, required: %w[query], read_only: true),
          tool("list_purchases", "The products the connected creator bought, newest first, so an assistant can answer \"what did I buy?\" and open it. Each purchase links to the creator's library. When next_cursor is returned, pass it as cursor for the next page.", {
                 "limit" => { type: "integer", description: "Max purchases to return (1-50, default 25)." },
                 "cursor" => { type: "string", description: "next_cursor from the previous page." }
               }, read_only: true),
          tool("create_bundle", "Create a draft bundle: one product that sells several of the creator's own products together at the bundle's own price. It is not for sale until publish_product runs. Confirm the products and the price with the creator first.", {
                 "name" => { type: "string", description: "Bundle name." },
                 "price_cents" => { type: "integer", description: "Price of the bundle in minor units (cents for USD). It is not derived from the products it contains; use 0 for a free bundle." },
                 "product_ids" => { type: "array", items: { type: "string" }, minItems: 1, description: "Ids or permalinks of the creator's products the bundle sells, in the order they should appear. A product sold in versions is added at its first version." }
               }, required: %w[name price_cents product_ids]),
          tool("update_bundle", "Replace the products a bundle sells. The bundle keeps its name, price, description, and published state; use update_product for the name, price, or description, and publish_product or unpublish_product for its state. Confirm the new list with the creator first.", {
                 "id" => { type: "string", description: "Bundle id or permalink." },
                 "product_ids" => { type: "array", items: { type: "string" }, minItems: 1, description: "Ids or permalinks of the creator's products the bundle should sell, in the order they should appear. This list replaces the bundle's current products. A product the bundle already sells keeps its version and quantity." }
               }, required: %w[id product_ids], destructive: true),
          tool("create_discount_code", "Create a discount code for all of the creator's products, or for one product. Pass exactly one of percent_off or amount_cents. Confirm the code, the amount, and which products it covers with the creator first, and call this once per confirmation: an existing code is refused, not duplicated.", {
                 "code" => { type: "string", description: "The code buyers enter. Letters, numbers, dashes, and underscores." },
                 "product_id" => { type: "string", description: "Product id or permalink. Omit for a code that covers all of the creator's products." },
                 **DISCOUNT_CODE_FIELDS
               }, required: %w[code]),
          tool("update_discount_code", "Change the amount, dates, or usage limit of an existing discount code. Pass only the fields to change. A code that covers several products changes for all of them. Confirm the changes with the creator first.", {
                 "code" => { type: "string", description: "The existing code." },
                 "product_id" => { type: "string", description: "Product id or permalink, for a code made for specific products. Omit for a code that covers all products." },
                 **DISCOUNT_CODE_FIELDS
               }, required: %w[code], destructive: true),
          tool("expire_discount_code", "End a discount code now so buyers can no longer use it. The code is kept and shows as expired; update_discount_code with a later expires_at reopens it. Expiring a code that has already expired changes nothing and succeeds. Confirm with the creator first.", {
                 "code" => { type: "string", description: "The existing code." },
                 "product_id" => { type: "string", description: "Product id or permalink, for a code made for specific products. Omit for a code that covers all products." }
               }, required: %w[code], destructive: true)
        ]
      end

      # Every tool here reaches a creator's storefront: an independently controlled,
      # publicly reachable system, so it is open-world by default. Pass
      # open_world: false only for a tool that touches nothing but closed local state.
      def tool(name, description, properties, required: [], read_only: false, destructive: false, open_world: true)
        schema = { type: "object", properties:, additionalProperties: false }
        schema[:required] = required if required.any?
        {
          name:,
          title: name.humanize,
          description:,
          inputSchema: schema,
          annotations: {
            readOnlyHint: read_only,
            openWorldHint: open_world,
            destructiveHint: destructive
          }
        }
      end

      def call_tool(params)
        name = params["name"]
        definition = tools.find { |tool| tool[:name] == name }
        # A retired or misspelled name is the caller's mistake, and tool_bucket folds it into
        # OTHER, so a client stuck on an old tool list still shows up.
        raise InvalidArguments.new("Unknown tool: #{name}", code: -32602) unless definition

        arguments = params.fetch("arguments", {})
        raise InvalidArguments.new("arguments must be an object", code: -32602) unless arguments.is_a?(Hash)
        validate_tool_arguments!(definition[:inputSchema], arguments)

        payload = send("tool_#{name}", arguments)
        response = { content: [{ type: "text", text: JSON.pretty_generate(payload) }], structuredContent: payload }
        # Counted only once the response is serialised, so a payload that cannot be rendered is
        # not recorded as a success.
        count_tool(name, "ok")
        response
      rescue InvalidArguments
        # The caller never reached the tool, and the fix is on the client side.
        count_tool(name, "invalid")
        raise
      rescue InsufficientScope, MissingScope
        # Losing a creator to a missing scope is a funnel step, not an error to bury.
        count_tool(name, "scope")
        raise
      rescue ToolError, Link::LinkInvalid, ActiveRecord::RecordInvalid => e
        count_tool(name, "error")
        message = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
        { content: [{ type: "text", text: message }], isError: true }
      rescue Error
        # A tool that rejected the call itself (a missing price, an unknown category) is an error
        # the caller saw, so it counts, and the JSON-RPC layer still answers it.
        count_tool(name, "error")
        raise
      rescue StandardError
        # A tool that crashed is exactly the call the counter must not hide: count it, then let the
        # exception travel as it did before.
        count_tool(name, "error")
        raise
      end

      # One counter per call, best-effort: telemetry never changes what the caller gets back.
      # A call with no name at all still counts, folded into OTHER by tool_bucket, so a malformed
      # tools/call cannot vanish from the tool counter while it shows up in the protocol counter.
      def count_tool(name, outcome)
        @tool_counts[ProtocolTelemetry.tool_bucket(name, outcome)] += 1
      end

      def validate_tool_arguments!(schema, arguments)
        (schema[:required] || []).each do |key|
          raise InvalidArguments.new("#{key} is required", code: -32602) unless arguments.key?(key)
        end
        arguments.each do |key, value|
          property = schema[:properties][key]
          raise InvalidArguments.new("Unknown argument: #{key}", code: -32602) unless property

          types = { "integer" => [Integer], "array" => [Array], "boolean" => [TrueClass, FalseClass] }.fetch(property[:type], [String])
          raise InvalidArguments.new("#{key} must be #{property[:type] == 'array' ? 'an' : 'a'} #{property[:type]}", code: -32602) unless types.any? { |type| value.is_a?(type) }
          raise InvalidArguments.new("#{key} must be one of: #{property[:enum].join(', ')}", code: -32602) if property[:enum] && !property[:enum].include?(value)
        end
      end

      def tool_get_account(_args)
        require_scopes!(:view_profile, :view_public, :view_sales, :account)
        {
          id: user.external_id,
          name: user.name,
          username: user.username,
          url: user.profile_url,
          currency: user.currency_type
        }
      end

      def tool_list_products(args)
        require_scopes!(:view_profile, :view_public, :edit_products, :account)
        products = user.products.visible.includes(:alive_prices, tier_categories: { alive_variants: :alive_prices })
        page, next_cursor = paginate(products, args, default: 25, table: "links")
        { products: page.map { |product| product_payload(product) }, next_cursor: }.compact
      end

      def tool_get_product(args)
        require_scopes!(:view_profile, :view_public, :edit_products, :account)
        product = find_product!(args["id"])
        details = { category: category_payload(product), description: product.description, summary: product.custom_summary, additional_details: additional_details_payload(product), tags: product.tags.pluck(:name), custom_receipt_text: product.custom_receipt_text, custom_view_content_button_text: product.custom_view_content_button_text, covers: covers_payload(product) }
        # A caller editing a bundle needs the members it has now, before replacing them.
        details[:bundle_products] = bundle_products_payload(product) if product.is_bundle?
        # The same rule as the public API: sales figures need a sales scope.
        details.merge!(sales_count: product.successful_sales_count, sales_usd_cents: product.total_usd_cents) if (token.scopes.to_a & %w[view_sales account]).any?
        { product: product_payload(product).merge(details) }
      end

      def tool_create_draft_product(args)
        membership = args["product_type"] == "membership"
        # Argument errors come before the scope check, so a bad call does not ask the creator for write access.
        currency = validated_currency!(args["currency"])
        if membership
          raise Error.new("price_cents is not accepted for a membership; set each tier's price_cents", code: -32602) if args.key?("price_cents")
          if args.key?("pay_what_you_want") || args.key?("suggested_price_cents")
            raise Error.new("pay_what_you_want and suggested_price_cents are not accepted for a membership; set them on each tier", code: -32602)
          end
          tiers = validated_tiers!(args["tiers"])
        else
          raise Error.new("price_cents is required", code: -32602) unless args.key?("price_cents")
          raise Error.new("tiers are only accepted with product_type membership", code: -32602) if args.key?("tiers")
          if args.key?("suggested_price_cents") && !args["pay_what_you_want"]
            raise Error.new("suggested_price_cents needs pay_what_you_want: true in the same call", code: -32602)
          end
        end

        require_scopes!(:edit_products, :account)
        name = args["name"].strip
        raise Error.new("name is required", code: -32602) if name.blank?
        return create_draft_membership(args, name, tiers, currency) if membership

        price_cents = args["price_cents"]
        raise Error.new("price_cents must be zero or more", code: -32602) if price_cents.negative?

        product = user.links.build(
          name:,
          description: args["description"].to_s,
          native_type: Link::NATIVE_TYPE_DIGITAL,
          price_cents:,
          customizable_price: args["pay_what_you_want"],
          suggested_price_cents: args["suggested_price_cents"],
          price_currency_type: currency,
          draft: true,
          purchase_disabled_at: Time.current,
          display_product_reviews: true
        )
        product.taxonomy = Taxonomy.find_by(slug: "other")
        product.save!
        { product: product_payload(product), message: "Draft saved. It is not for sale until publish_product." }
      end

      def create_draft_membership(args, name, tiers, currency)
        recurrence = tiers.first["recurrence"]
        product = user.links.build(
          name:,
          description: args["description"].to_s,
          native_type: Link::NATIVE_TYPE_MEMBERSHIP,
          is_recurring_billing: true,
          is_tiered_membership: true,
          should_show_all_posts: true,
          subscription_duration: recurrence,
          # Seeds the default tier's price, as the web create form does.
          price_cents: tiers.first["price_cents"],
          price_currency_type: currency,
          draft: true,
          purchase_disabled_at: Time.current,
          display_product_reviews: true
        )
        product.set_template_properties_if_needed
        product.taxonomy = Taxonomy.find_by(slug: "other")
        begin
          ActiveRecord::Base.transaction do
            # Saving a tiered membership adds an "Untitled" default tier; the first tier replaces it.
            product.save!
            options = tiers.each_with_index.map do |tier, index|
              {
                id: index.zero? ? product.default_tier.external_id : nil,
                name: tier["name"].strip,
                customizable_price: tier["pay_what_you_want"],
                # The tier updater refuses a suggested amount below the tier's price, as in the editor.
                recurrence_price_values: { recurrence => { enabled: true, price_cents: tier["price_cents"], suggested_price_cents: tier["suggested_price_cents"] } }
              }
            end
            Product::VariantsUpdaterService.new(product:, variants_params: [{ id: product.tier_category.external_id, name: product.tier_category.title, options: }]).perform
          end
        rescue Link::LinkInvalid => e
          # The tier services report through product.errors and raise with no message.
          raise ToolError, product.errors.full_messages.to_sentence.presence || e.message
        end
        { product: product_payload(product.reload), message: "Draft membership saved. It is not for sale until publish_product." }
      end

      def validated_tiers!(tiers)
        raise Error.new("tiers are required for a membership", code: -32602) if tiers.blank?

        tiers.each_with_index do |tier, index|
          raise Error.new("tiers[#{index}] must be an object", code: -32602) unless tier.is_a?(Hash)
          unknown = tier.keys - TIER_KEYS - TIER_PRICING_KEYS
          raise Error.new("tiers[#{index}] has unknown argument: #{unknown.first}", code: -32602) if unknown.any?
          missing = TIER_KEYS - tier.keys
          raise Error.new("tiers[#{index}].#{missing.first} is required", code: -32602) if missing.any?
          raise Error.new("tiers[#{index}].name must be a non-blank string", code: -32602) unless tier["name"].is_a?(String) && tier["name"].strip.present?
          raise Error.new("tiers[#{index}].price_cents must be an integer of zero or more", code: -32602) unless tier["price_cents"].is_a?(Integer) && tier["price_cents"] >= 0
          raise Error.new("tiers[#{index}].price_cents must be at most #{BasePrice::Shared::MAX_PRICE_CENTS}", code: -32602) if tier["price_cents"] > BasePrice::Shared::MAX_PRICE_CENTS
          raise Error.new("tiers[#{index}].pay_what_you_want must be a boolean", code: -32602) if tier.key?("pay_what_you_want") && ![true, false].include?(tier["pay_what_you_want"])
          if tier.key?("suggested_price_cents")
            suggested_price_cents = tier["suggested_price_cents"]
            raise Error.new("tiers[#{index}].suggested_price_cents must be an integer of zero or more", code: -32602) unless suggested_price_cents.is_a?(Integer) && suggested_price_cents >= 0
            raise Error.new("tiers[#{index}].suggested_price_cents must be at most #{BasePrice::Shared::MAX_PRICE_CENTS}", code: -32602) if suggested_price_cents > BasePrice::Shared::MAX_PRICE_CENTS
            raise Error.new("tiers[#{index}].suggested_price_cents needs pay_what_you_want: true on the same tier", code: -32602) unless tier["pay_what_you_want"] == true
          end
          unless BasePrice::Recurrence::ALLOWED_RECURRENCES.include?(tier["recurrence"])
            raise Error.new("tiers[#{index}].recurrence must be one of: #{BasePrice::Recurrence::ALLOWED_RECURRENCES.join(', ')}", code: -32602)
          end
        end
        # The product editor holds every tier to the same set of billing periods.
        raise Error.new("every tier must use the same recurrence", code: -32602) if tiers.map { _1["recurrence"] }.uniq.size > 1

        tiers
      end

      # The product editor's currency list. Absent means the creator's own currency, which is what
      # the web create form defaults to; anything else has to be one of CURRENCIES, in any case.
      def validated_currency!(value)
        return user.currency_type if value.nil?

        currency = value.to_s.strip.downcase
        raise Error.new("currency must be one of: #{CURRENCIES.join(', ')}", code: -32602) unless CURRENCIES.include?(currency)

        currency
      end

      def tool_update_product(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        changes = args.slice("name", "description", "summary", "additional_details", "category", "tags", "price_cents", "currency", "pay_what_you_want", "suggested_price_cents", "custom_receipt_text", "custom_view_content_button_text", "permalink")
        raise Error.new("Pass at least one of name, description, summary, additional_details, category, tags, price_cents, currency, pay_what_you_want, suggested_price_cents, custom_receipt_text, custom_view_content_button_text, or permalink", code: -32602) if changes.empty?

        # Resolved before the transaction: an unknown category or currency is an argument error,
        # not a rollback.
        taxonomy = resolve_category!(changes["category"]) if changes.key?("category")
        currency = validated_currency!(changes["currency"]) if changes.key?("currency")

        # An empty permalink is how the editor clears a custom URL, so it must stay distinct from "unchanged".
        # Whitespace-only is neither: allowing it through would store a value the model treats as blank
        # (allow_blank skips the format rule), so refuse it and say how to clear instead.
        if changes.key?("permalink")
          permalink = changes["permalink"]
          if permalink.empty?
            permalink = nil
          elsif permalink.blank?
            raise Error.new("permalink must not be blank. Send an empty string to go back to the default URL.", code: -32602)
          end
        end

        # A currency change moves every price row, so it is decided under the lock below; the
        # warning after the save needs to know whether it happened, and which discount codes were
        # attached before it did.
        currency_changed = false
        codes_before_currency_change = nil
        # `price_cents=` saves its Price row at once, so a later validation failure must roll it back.
        ActiveRecord::Base.transaction do
          if changes.key?("permalink")
            # Seller row before product row, the order the editor and the v2 API lock in. Called even when
            # the slug looks unchanged: the pre-lock read can be stale, and the helper raises rather than
            # lock the seller after the product.
            product.lock_for_permalink_claim!(permalink)
          else
            # Reloads under the lock: the upsell diff below must compare against the committed
            # description, or an overlapping edit's new upsell card is dropped with its offer left active.
            product.lock!
          end
          if changes.key?("name")
            name = changes["name"].strip
            raise Error.new("name must not be blank", code: -32602) if name.blank?

            product.name = name
          end
          # Currency before price: `price_cents=` writes its Price row scoped to the currency in
          # force at that moment, so the amounts have to be carried into the new currency or the
          # product is left with no price in it. This is the v2 API's carry, rental price
          # included (a buy_and_rent product would otherwise lose its rental offer).
          if changes.key?("currency") && currency != product.price_currency_type
            if product.is_tiered_membership
              raise ToolError, "Currency cannot be changed for a membership with tiers: its tier prices are stored per currency. Change it in the product editor."
            end
            raise ToolError, "Currency cannot be changed for a product sold on more than one payment option: only one of its prices could be carried across. Change it in the product editor." if product.has_multiple_recurrences?

            # universal_offer_codes is scoped to the product's price_currency_type, so the codes
            # denominated in the old currency leave that list the moment the new one lands: capture
            # them first, or the warning below never sees the codes this change strands.
            # Bundles::ProductController#update takes the same precaution.
            codes_before_currency_change = product.product_and_universal_offer_codes
            carried_price_cents = product.default_price_cents
            carried_rental_price_cents = product.rentable? ? product.rental_price_cents : nil
            previous_currency = product.price_currency_type
            product.price_currency_type = currency
            # The tools have no rental price field, so a rental price the new currency rejects is
            # refused by name, as the editor does; the generic price error would point at price_cents.
            if product.buy_and_rent? && carried_rental_price_cents.present? && (violation = product.price_range_violation(carried_rental_price_cents))
              rental_price = ->(currency_type) { MoneyFormatter.format(carried_rental_price_cents, currency_type.to_sym, no_cents_if_whole: true, symbol: true) }
              problem = violation == :below_minimum ? "below the #{product.min_price_formatted} minimum" : "above the price limit"
              raise ToolError, "Currency cannot be changed: the #{rental_price.(previous_currency)} rental price would become #{rental_price.(currency)}, #{problem}. Keep the current currency, or contact Gumroad support."
            end
            product.price_cents = carried_price_cents if carried_price_cents.present?
            product.rental_price_cents = carried_rental_price_cents if carried_rental_price_cents.present?
            # available_price_cents reads every alive buy row, so one left in the old currency would be
            # checked against the new currency's minimum below; retire it, as save_recurring_prices! does.
            retired_prices = product.prices.alive.where.not(currency: currency)
            retired_prices.map(&:mark_deleted!)
            product.enqueue_index_update_for(["price_cents", "available_price_cents"]) if retired_prices.any?
            currency_changed = true
          end
          if changes.key?("price_cents")
            raise Error.new("price_cents must be zero or more", code: -32602) if changes["price_cents"].negative?
            # Tier prices live on the variants; the product-level price is a placeholder.
            raise ToolError, "Price cannot be changed for a membership with tiers. Edit the tier prices in the product editor." if product.is_tiered_membership

            product.price_cents = changes["price_cents"]
          end
          if changes.key?("pay_what_you_want") || changes.key?("suggested_price_cents")
            # A membership with tiers keeps both on its tiers, priced per billing period.
            raise ToolError, "Pay what you want is set on each tier of a membership, not on the product. Edit the tiers in the product editor." if product.is_tiered_membership
          end
          # After price_cents: the suggested price is validated against the price set in this save.
          product.customizable_price = changes["pay_what_you_want"] if changes.key?("pay_what_you_want")
          if changes.key?("suggested_price_cents")
            # Checked against the switch the lock reloaded, not the pre-lock read: an amount stored
            # while it is off reads back as no suggested price, so the caller's write would look lost.
            raise Error.new("suggested_price_cents needs pay what you want on: pass pay_what_you_want: true in this call", code: -32602) unless product.customizable_price?

            product.suggested_price_cents = changes["suggested_price_cents"]
          end
          if changes.key?("description")
            product.description = SaveContentUpsellsService.new(seller: user, content: changes["description"], old_content: product.description).from_html
          end
          # The same json_data key the editor's Summary field writes; an empty value clears it.
          product.json_data = product.json_data.to_h.merge("custom_summary" => changes["summary"].to_s.presence) if changes.key?("summary")
          # The same json_data keys the editor's Additional details rows write; the list is replaced whole.
          product.json_data = product.json_data.to_h.merge("custom_attributes" => normalized_additional_details(changes["additional_details"])) if changes.key?("additional_details")
          # The Receipt tab's two fields, the same json_data keys the editor writes; an empty value clears one.
          product.json_data = product.json_data.to_h.merge("custom_receipt_text" => changes["custom_receipt_text"].to_s.presence) if changes.key?("custom_receipt_text")
          product.json_data = product.json_data.to_h.merge("custom_view_content_button_text" => changes["custom_view_content_button_text"].to_s.presence) if changes.key?("custom_view_content_button_text")
          # Link's validations enforce the editor's permalink rules, and its after_commit redirects the outgoing slug.
          product.custom_permalink = permalink if changes.key?("permalink")
          product.taxonomy = taxonomy if taxonomy
          # The editor re-normalizes the seller's answers on a category switch; clearing them in this
          # save keeps the taxonomy change the last write, so the product's after_commit classification
          # still sees it and a second save does not swallow the callback.
          product.json_data = product.json_data.to_h.merge("taxonomy_attribute_values" => {}) if taxonomy && product.taxonomy_id_changed?
          product.save!
          # Tag rows after the product row, in the same transaction, so one call still saves
          # all-or-nothing with every field above.
          product.save_tags!(normalized_tags(changes["tags"], product)) if changes.key?("tags")
        end
        result = { product: product_payload(product.reload).merge(category: category_payload(product), description: product.description, summary: product.custom_summary, additional_details: additional_details_payload(product), tags: product.tags.pluck(:name), custom_receipt_text: product.custom_receipt_text, custom_view_content_button_text: product.custom_view_content_button_text) }
        # A lower price can push an existing discount below the minimum, and a new currency strands
        # the codes denominated in the old one; the editor warns rather than refuses. Both checks run
        # on either change: the minimum is per currency, so re-denominating at the same number can
        # put a percentage code under the new currency's minimum with nothing else moved.
        if changes.key?("price_cents") || currency_changed
          codes = (codes_before_currency_change || []) | product.product_and_universal_offer_codes
          mismatched_codes = currency_changed ? codes.reject { _1.is_currency_valid?(product) } : []
          # A code in the wrong currency no longer applies at all, so it is named only once, above.
          below_minimum_codes = (codes - mismatched_codes).reject { _1.is_amount_valid?(product) }.map(&:code)
          warnings = []
          # Not "delete": an all-products code, or one shared with other products, still works on those.
          warnings << "These discount codes are in a different currency than the product now uses, so they no longer apply to it: #{mismatched_codes.map(&:code).join(', ')}. Edit them in Gumroad if they should." if mismatched_codes.any?
          warnings << "These discount codes would discount this product below #{product.min_price_formatted}: #{below_minimum_codes.join(', ')}. Edit or delete them in Gumroad." if below_minimum_codes.any?
          result[:warning] = warnings.join(" ") if warnings.any?
        end
        result
      rescue Link::PermalinkChangedDuringLock
        raise ToolError, "This product's URL changed while the update was waiting. Nothing was saved; try the update again."
      end

      def tool_add_cover(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        cover = product.asset_previews.build
        begin
          cover.url = args["url"]
        rescue *INTERNET_EXCEPTIONS => e
          status = " The link returned HTTP #{e.message}." if e.is_a?(OpenURI::HTTPError)
          raise ToolError, "Could not fetch an image from that URL.#{status} Use a public https link to the image file."
        end
        cover.analyze_file
        unless cover.save
          cover.file.blob&.purge if cover.file.attached?
          raise ToolError, cover.errors.full_messages.to_sentence
        end

        { product: product_payload(product), covers: covers_payload(product.reload) }
      end

      def bundle_products_payload(product)
        product.bundle_products.alive.in_order.includes(:product, :variant).map do |bundle_product|
          {
            id: bundle_product.product.external_id,
            name: bundle_product.product.name,
            variant_id: bundle_product.variant&.external_id,
            quantity: bundle_product.quantity
          }
        end
      end

      def files_payload(product)
        product.alive_product_files.map do |file|
          {
            id: file.external_id,
            name: file.name_displayable,
            type: file.display_extension,
            size_bytes: file.size.to_i,
            position: file.position
          }
        end
      end

      def covers_payload(product)
        product.display_asset_previews.map { |preview| { id: preview.guid, url: preview.url, type: preview.display_type } }
      end

      # The rows the product page shows in the card with the summary: the editor's Additional
      # details, in order, with the same blank rows skipped as the presenters skip.
      def additional_details_payload(product)
        product.custom_attributes.filter_map do |row|
          { name: row["name"], value: row["value"] } if row["name"].present? || row["value"].present?
        end
      end

      # The editor's tag picker takes up to ten tags of two to twenty characters, and a product that
      # already has more than ten can only lose them. The rest of the Tag rules (no commas, no
      # leading hash) are its own.
      def normalized_tags(tags, product)
        names = tags.map do |tag|
          raise Error.new("each tag must be text", code: -32602) unless tag.is_a?(String)

          tag.downcase.strip.gsub(/[[:space:]]+/, " ")
        end.uniq
        raise Error.new("each tag must be #{MIN_TAG_LENGTH}-#{MAX_TAG_LENGTH} characters", code: -32602) if names.any? { !_1.length.between?(MIN_TAG_LENGTH, MAX_TAG_LENGTH) }
        raise Error.new("a product can have up to #{MAX_TAGS} tags", code: -32602) if names.length > MAX_TAGS && names.length >= product.tags.length

        names
      end

      def normalized_additional_details(rows)
        rows.map do |row|
          raise Error.new("each additional detail must be an object with name and value", code: -32602) unless row.is_a?(Hash)

          name = additional_detail_text(row["name"], "name")
          value = additional_detail_text(row["value"], "value")
          # The editor keeps a row only when it has a name, so a value on its own is refused rather
          # than dropped without telling the caller.
          raise Error.new("each additional detail needs a name", code: -32602) if name.blank? && value.present?

          { "name" => name, "value" => value }
        end.reject { _1["name"].blank? && _1["value"].blank? }
      end

      # Both fields are declared as strings. Anything else would be stored as Ruby's own text for
      # the object and shown to buyers as the value, so it is refused rather than coerced.
      def additional_detail_text(field, key)
        return "" if field.nil?

        raise Error.new("additional detail #{key} must be text", code: -32602) unless field.is_a?(String)

        field
      end

      def tool_list_files(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        { product: product_payload(product), files: files_payload(product) }
      end

      def tool_add_file(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        url = args["url"].to_s.strip
        content = args["content"]
        raise Error.new("content must be a string", code: -32602) unless content.nil? || content.is_a?(String)
        # An empty string is a caller that meant to pass nothing, not a file of zero bytes.
        has_content = content.present?
        raise Error.new("Pass url or content, not both", code: -32602) if url.present? && has_content
        raise Error.new("url is required, or pass content and filename to write the file out here", code: -32602) if url.blank? && !has_content

        inline = url.blank?
        begin
          file = if inline
            filename = args["filename"].to_s.strip
            raise Error.new("filename is required with content", code: -32602) if filename.blank?

            Mcp::ProductFileIngest.new(seller: user, product:, display_name: args["display_name"]).perform_inline(content:, filename:)
          else
            Mcp::ProductFileIngest.new(seller: user, product:, url:, display_name: args["display_name"]).perform
          end
        rescue Mcp::ProductFileIngest::InvalidContent => e
          raise Error.new(e.message, code: -32602)
        rescue Mcp::ProductFileIngest::TooLarge
          limit = (inline ? Mcp::ProductFileIngest::INLINE_MAX_BYTES : Mcp::ProductFileIngest::MAX_BYTES) / 1.megabyte
          action = inline ? "can write out here" : "can fetch"
          raise ToolError, "That file is larger than #{limit} MB, which is the most this tool #{action}. Upload it in the product editor instead: #{product.long_url}/edit"
        rescue Mcp::ProductFileIngest::InvalidUrl, *INTERNET_EXCEPTIONS
          raise ToolError, if inline
            "Could not store that file right now. Try again, or upload it in the product editor."
          else
            "Could not download a file from that URL. Use a public https link to the file itself."
          end
        rescue Mcp::ProductFileIngest::DownloadFailed
          raise ToolError, "That link did not return a file. Use a public https link to the file itself."
        rescue Aws::S3::Errors::ServiceError
          raise ToolError, "The file could not be stored. Try again, or upload it in the product editor."
        rescue *ProductFile::EXPECTED_ENQUEUE_ERRORS
          raise ToolError, "The file was attached, but the processing that follows it could not be started. Add it again to retry."
        end

        product.reload
        { product: product_payload(product), files: files_payload(product), message: "#{file&.name_displayable || 'File'} is now attached to #{product.name}." }
      end

      def tool_add_content_link(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        url = args["url"].to_s.strip
        raise Error.new("url is required", code: -32602) if url.blank?

        begin
          links = Mcp::ProductContentLink.new(product:, url:, label: args["label"]).perform
        rescue Mcp::ProductContentLink::BlockedScheme
          raise ToolError, "A content link cannot use a #{RichContent::BLOCKED_HREF_SCHEMES.join(', ')} URL, because a browser would run it instead of opening a page."
        rescue Mcp::ProductContentLink::InvalidUrl
          raise ToolError, "That is not a link. Use a full URL, like https://example.com/your-template."
        end

        { product: product_payload(product.reload), links:, message: "Buyers now see this link as a button on #{product.name}'s content page." }
      end

      def tool_publish_product(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        product.publish!
        { product: product_payload(product.reload) }
      end

      def tool_unpublish_product(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        product.unpublish!
        { product: product_payload(product.reload) }
      end

      def tool_list_sales(args)
        require_scopes!(:view_sales, :account)
        sales = user.sales.successful_or_preorder_authorization_successful
          .includes(:link, :offer_code, :utm_link, :subscription)
        sales = sales.where(email: args["email"].to_s.strip) if args["email"].present?
        sales = sales.where(link_id: find_product!(args["product_id"]).id) if args["product_id"].present?
        sales = sales.where(purchases: { created_at: parse_time!(args["after"], "after").. }) if args["after"].present?
        sales = sales.where(purchases: { created_at: ...parse_time!(args["before"], "before") }) if args["before"].present?
        sales = sales.where(args["payment"] == "paid" ? "purchases.price_cents > 0" : "purchases.price_cents = 0") if args["payment"]
        if args["kind"]
          membership = "purchases.subscription_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM subscriptions WHERE subscriptions.id = purchases.subscription_id AND subscriptions.flags & #{Subscription.flag_mapping["flags"][:is_installment_plan]} != 0)"
          sales = sales.where(args["kind"] == "subscription" ? membership : "NOT (#{membership})")
        end
        page, next_cursor = paginate(sales, args, default: 25, table: "purchases")
        { sales: page.map { |sale| sale_payload(sale) }, next_cursor: }.compact
      end

      def sale_payload(sale)
        utm = sale.utm_link
        {
          id: sale.external_id,
          email: sale.email,
          product_id: sale.link.external_id,
          product_name: sale.link.name,
          price_cents: sale.price_cents,
          fee_cents: sale.fee_cents.to_i,
          affiliate_commission_cents: sale.affiliate_credit_cents.to_i,
          net_cents: sale.price_cents - sale.fee_cents.to_i - sale.affiliate_credit_cents.to_i,
          currency: Currency::USD,
          created_at: sale.created_at.iso8601,
          refunded: sale.refunded?,
          chargedback: sale.chargedback?,
          subscription: sale.subscription.present? && !sale.subscription.is_installment_plan?,
          country: sale.country_or_ip_country,
          discount_code: sale.offer_code&.code,
          referrer: sale.referrer.presence,
          utm_source: utm&.utm_source,
          utm_medium: utm&.utm_medium,
          utm_campaign: utm&.utm_campaign,
          utm_term: utm&.utm_term,
          utm_content: utm&.utm_content
        }
      end

      def tool_get_analytics(args)
        require_scopes!(:view_sales, :account)
        timezone = ActiveSupport::TimeZone[user.timezone]
        end_date = args["end_date"] ? parse_date!(args["end_date"], "end_date") : timezone.today
        start_date = args["start_date"] ? parse_date!(args["start_date"], "start_date") : end_date - (ANALYTICS_DEFAULT_DAYS - 1)
        raise Error.new("start_date must not be after end_date", code: -32602) if start_date > end_date
        raise Error.new("The date range cannot exceed #{ANALYTICS_MAX_DAYS} days", code: -32602) if (end_date - start_date).to_i >= ANALYTICS_MAX_DAYS

        product = find_product!(args["product_id"]) if args["product_id"].present?
        by = args.fetch("breakdown", "product")
        # CachingProxy clamps ranges to [account creation, today]; a range wholly outside would be answered with another day's data.
        created_on = user.created_at.in_time_zone(timezone).to_date
        if start_date > timezone.today || end_date < created_on
          rows = []
        else
          data = CreatorAnalytics::CachingProxy.new(user).data_for_dates(start_date, end_date, by: by == "referrer" ? :referral : :date)
          permalinks = product ? [product.unique_permalink] : nil
          rows = by == "referrer" ? analytics_by_referrer(data[:by_referral], permalinks) : analytics_by_product(data[:by_date], permalinks)
        end
        { start_date: start_date.iso8601, end_date: end_date.iso8601, time_zone: user.timezone, currency: Currency::USD, breakdown: by, rows: }
      rescue Faraday::TimeoutError
        raise ToolError, "Analytics took too long for this range. Try a shorter range."
      end

      def analytics_by_product(by_date, permalinks)
        names = user.links.where(unique_permalink: by_date[:views].keys).index_by(&:unique_permalink)
        by_date[:views].keys.filter_map do |permalink|
          next if permalinks && !permalinks.include?(permalink)

          views = by_date[:views][permalink].sum
          sales = by_date[:sales][permalink].sum
          { product_id: names[permalink]&.external_id, product_name: names[permalink]&.name, views:, sales:, revenue_cents: by_date[:totals][permalink].sum, conversion_rate: analytics_conversion(sales, views) }
        end.sort_by { |row| -row[:views] }
      end

      def analytics_by_referrer(by_referral, permalinks)
        totals = Hash.new { |hash, name| hash[name] = { views: 0, sales: 0, revenue_cents: 0 } }
        { views: :views, sales: :sales, totals: :revenue_cents }.each do |type, field|
          by_referral[type].each do |permalink, referrers|
            next if permalinks && !permalinks.include?(permalink)

            referrers.each { |name, series| totals[name][field] += series.sum }
          end
        end
        totals.map { |name, row| { referrer: name, **row, conversion_rate: analytics_conversion(row[:sales], row[:views]) } }
          .sort_by { |row| -row[:views] }.first(ANALYTICS_MAX_REFERRERS)
      end

      def analytics_conversion(sales, views)
        views.positive? ? (sales.to_f / views).round(4) : nil
      end

      def tool_get_sales_totals(args)
        require_scopes!(:view_sales, :account)
        timezone = ActiveSupport::TimeZone[user.timezone]
        end_date = args["end_date"] ? parse_date!(args["end_date"], "end_date") : timezone.today
        start_date = args["start_date"] ? parse_date!(args["start_date"], "start_date") : end_date - (TOTALS_DEFAULT_DAYS - 1)
        raise Error.new("start_date must not be after end_date", code: -32602) if start_date > end_date
        raise Error.new("The date range cannot exceed #{TOTALS_MAX_DAYS} days", code: -32602) if (end_date - start_date).to_i >= TOTALS_MAX_DAYS

        breakdown = args.fetch("breakdown", "product")
        # The revenue definition every other report uses: a successful or preorder-authorized sale
        # that was not refunded or charged back. Bundle members are extra rows for one order. A
        # commission completion is a second payment on the order: it adds revenue but not a unit.
        sales = user.sales
          .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
          .not_is_bundle_product_purchase
        sales = sales.where(link_id: find_product!(args["product_id"]).id) if args["product_id"].present?

        buckets = sales_total_buckets(sales, timezone, start_date, end_date, breakdown)
        {
          start_date: start_date.iso8601,
          end_date: end_date.iso8601,
          time_zone: user.timezone,
          currency: Currency::USD,
          breakdown:,
          totals: sales_totals_from(buckets.values),
          rows: sales_total_rows(buckets, breakdown)
        }
      end

      # Each bucket is [revenue_cents, units]. The range is walked in constant-offset segments
      # because the local bucket of a sale depends on the zone offset in force at that sale.
      def sales_total_buckets(sales, timezone, start_date, end_date, breakdown)
        start_time = Time.at(timezone.parse(start_date.to_s).to_i).utc
        end_time = Time.at(timezone.parse((end_date + 1).to_s).to_i).utc
        buckets = Hash.new { |hash, key| hash[key] = [0, 0] }
        completion_flag = Purchase.flag_mapping["flags"][:is_commission_completion_purchase]
        units_sql = "SUM(CASE WHEN (purchases.flags & #{completion_flag}) = 0 THEN 1 ELSE 0 END)"

        local_offset_segments(timezone, start_time, end_time).each do |segment_start, segment_end, offset_seconds|
          expression = sales_group_expression(breakdown, offset_seconds)
          sales.where(created_at: segment_start...segment_end)
            .group(Arel.sql(expression))
            .pluck(Arel.sql(expression), Arel.sql("SUM(purchases.price_cents)"), Arel.sql(units_sql))
            .each do |key, revenue_cents, units|
              bucket = buckets[sales_group_key(breakdown, key)]
              bucket[0] += revenue_cents.to_i
              bucket[1] += units.to_i
            end
        end

        buckets
      end

      # MySQL can't convert to a named zone (the time zone tables aren't loaded), so local buckets
      # are the UTC time shifted by the zone's offset. A range can contain a daylight-saving change,
      # so each constant-offset segment is shifted on its own rather than the whole range at once.
      def local_offset_segments(timezone, start_time, end_time)
        transitions = timezone.tzinfo.transitions_up_to(end_time, start_time).map { |transition| Time.at(transition.at.to_i).utc }
        ([start_time] + transitions + [end_time]).uniq.each_cons(2).map do |segment_start, segment_end|
          [segment_start, segment_end, timezone.at(segment_start.to_i).utc_offset]
        end
      end

      def sales_group_expression(breakdown, offset_seconds)
        return "purchases.link_id" if breakdown == "product"
        return "COALESCE(NULLIF(TRIM(purchases.country), ''), purchases.ip_country)" if breakdown == "country"

        local_date = "DATE(DATE_ADD(purchases.created_at, INTERVAL #{offset_seconds} SECOND))"
        case breakdown
        when "day" then local_date
        when "week" then "DATE_SUB(#{local_date}, INTERVAL WEEKDAY(#{local_date}) DAY)"
        else "DATE_FORMAT(#{local_date}, '%Y-%m-01')"
        end
      end

      def sales_group_key(breakdown, key)
        return key.to_i if breakdown == "product"
        return canonical_country_name(key.presence) if breakdown == "country"

        Date.parse(key.to_s)
      end

      # Purchases store the country as free text, so one country can arrive under several spellings.
      def canonical_country_name(name)
        return name if name.nil?

        Compliance::Countries.find_by_name(name)&.common_name || name
      end

      def sales_total_rows(buckets, breakdown)
        case breakdown
        when "product"
          top = buckets.sort_by { |_product_id, (revenue_cents, _units)| -revenue_cents }.first(TOTALS_MAX_ROWS)
          products = Link.where(id: top.map(&:first)).select(:id, :name).index_by(&:id)
          top.map { |product_id, (revenue_cents, units)| { product_id: products[product_id]&.external_id, product_name: products[product_id]&.name, **sales_metrics(revenue_cents, units) } }
        when "country"
          buckets.map { |country, (revenue_cents, units)| { country:, **sales_metrics(revenue_cents, units) } }
            .sort_by { |row| -row[:revenue_cents] }.first(TOTALS_MAX_ROWS)
        else
          buckets.map { |date, (revenue_cents, units)| { date: date.iso8601, **sales_metrics(revenue_cents, units) } }
            .sort_by { |row| row[:date] }
        end
      end

      def sales_totals_from(buckets)
        sales_metrics(buckets.sum { |revenue_cents, _units| revenue_cents }, buckets.sum { |_revenue_cents, units| units })
      end

      def sales_metrics(revenue_cents, units)
        { revenue_cents:, units:, average_order_value_cents: units.positive? ? (revenue_cents.to_f / units).round : nil }
      end

      def parse_date!(value, name)
        Date.iso8601(value)
      rescue Date::Error
        raise Error.new("#{name} must be a date like 2026-10-31", code: -32602)
      end

      def tool_get_customers(args)
        require_scopes!(:view_sales, :account)
        by = args.fetch("breakdown", "spend")
        limit = limit_for(args, default: CUSTOMERS_DEFAULT_ROWS)
        start_date = parse_date!(args["start_date"], "start_date") if args["start_date"].present?
        end_date = parse_date!(args["end_date"], "end_date") if args["end_date"].present?
        raise Error.new("start_date must not be after end_date", code: -32602) if start_date && end_date && start_date > end_date

        zone = ActiveSupport::TimeZone[user.timezone]
        sales = user.sales.successful_or_preorder_authorization_successful
        sales = sales.where(email: args["email"].to_s.strip) if args["email"].present?
        rows = WithMaxExecutionTime.timeout_queries(seconds: CUSTOMERS_QUERY_TIMEOUT) do
          if by == "conversion"
            customers_by_conversion(sales, zone, start_date, end_date, limit)
          else
            customers_by_spend(sales, zone, start_date, end_date, limit)
          end
        end
        { breakdown: by, currency: Currency::USD, time_zone: user.timezone, start_date: start_date&.iso8601, end_date: end_date&.iso8601, rows: }
      rescue WithMaxExecutionTime::QueryTimeoutError, ActiveRecord::StatementTimeout
        raise ToolError, "Counting customers took too long. Try a shorter date range."
      end

      def customers_by_spend(sales, zone, start_date, end_date, limit)
        counted = customer_sales_range(sales, zone, start_date, end_date)
        sales = counted.joins("LEFT JOIN (#{customer_refunds_sql(counted)}) refund_totals ON refund_totals.purchase_id = purchases.id")
        refunds = "COALESCE(refund_totals.amount_cents, 0)"
        # A partial refund never sets stripe_refunded, so spend follows the refund amounts: the order
        # stays in the count, its money does not.
        spend = "SUM(CASE WHEN #{CUSTOMER_REFUNDED} OR #{customer_chargedback} THEN 0 ELSE GREATEST(COALESCE(purchases.price_cents, 0) - #{refunds}, 0) END)"
        refunded = "SUM(CASE WHEN #{CUSTOMER_REFUNDED} THEN COALESCE(purchases.price_cents, 0) ELSE #{refunds} END)"
        chargedback = "SUM(CASE WHEN #{customer_chargedback} THEN COALESCE(purchases.price_cents, 0) ELSE 0 END)"
        sales.group("purchases.email")
          .order(Arel.sql("#{spend} DESC, purchases.email ASC"))
          .limit(limit)
          .pluck(Arel.sql("purchases.email"), Arel.sql("COUNT(*)"), Arel.sql(spend), Arel.sql(refunded), Arel.sql(chargedback),
                 Arel.sql("MIN(purchases.created_at)"), Arel.sql("MAX(purchases.created_at)"))
          .map do |email, orders, spend_cents, refunded_cents, chargedback_cents, first_at, last_at|
            {
              email:,
              orders_count: orders,
              total_spend_cents: spend_cents.to_i,
              refunded_cents: refunded_cents.to_i,
              chargedback_cents: chargedback_cents.to_i,
              first_order_at: first_at&.iso8601,
              last_order_at: last_at&.iso8601
            }
          end
      end

      def customers_by_conversion(sales, zone, start_date, end_date, limit)
        free_at = "MIN(CASE WHEN #{CUSTOMER_FREE} THEN purchases.created_at END)"
        converted_at = "MIN(CASE WHEN #{customer_paid} THEN purchases.created_at END)"
        free_id = "MIN(CASE WHEN #{CUSTOMER_FREE} THEN purchases.id END)"
        converted_id = "MIN(CASE WHEN #{customer_paid} THEN purchases.id END)"
        # A buyer converted once a paid, kept purchase followed their first purchase of any kind,
        # and that first one was free. created_at carries no fractional seconds, so two orders in
        # the same second are settled by id.
        first_at = "MIN(purchases.created_at)"
        converted_after_free = "#{free_at} = #{first_at} AND (#{converted_at} > #{free_at} OR " \
                              "(#{converted_at} IS NOT NULL AND #{converted_at} = #{free_at} AND #{converted_id} > #{free_id}))"
        # The free purchase can be older than the range: the range bounds the purchase that converted.
        rows = sales.group("purchases.email").having(converted_after_free)
        rows = rows.having("#{converted_at} >= ?", customer_day_start(start_date, zone)) if start_date
        rows = rows.having("#{converted_at} < ?", customer_day_start(end_date, zone) + 1.day) if end_date
        # MySQL's `-` on two DATETIMEs is not a duration: it subtracts YYYYMMDDhhmmss numbers, so a
        # conversion over a month or a year boundary counts as slower than a longer one inside a
        # single month, and a capped list then drops the fastest converters. Order by the interval.
        rows.order(Arel.sql("TIMESTAMPDIFF(SECOND, #{free_at}, #{converted_at}) ASC, purchases.email ASC"))
          .limit(limit)
          .pluck(Arel.sql("purchases.email"), Arel.sql(free_at), Arel.sql(converted_at))
          .map do |email, first_free_at, paid_at|
            { email:, free_at: first_free_at&.iso8601, converted_at: paid_at&.iso8601, days_to_convert: ((paid_at - first_free_at) / 1.day).round(1) }
          end
      end

      def customer_sales_range(sales, zone, start_date, end_date)
        sales = sales.where("purchases.created_at >= ?", customer_day_start(start_date, zone)) if start_date
        sales = sales.where("purchases.created_at < ?", customer_day_start(end_date, zone) + 1.day) if end_date
        sales
      end

      # Refunds per purchase, pre-aggregated: joined directly they would multiply the buyer's orders.
      def customer_refunds_sql(sales)
        Refund.effective.joins(:purchase).merge(sales)
              .group("refunds.purchase_id").select("refunds.purchase_id, SUM(refunds.amount_cents) AS amount_cents").to_sql
      end

      # A won dispute keeps the money, so only an unreversed chargeback takes the order out of spend —
      # the same reversal the model's not_chargedback_or_chargedback_reversed scope reads.
      def customer_chargedback
        "purchases.chargeback_date IS NOT NULL AND COALESCE(purchases.flags & #{Purchase.flag_mapping["flags"][:chargeback_reversed]}, 0) = 0"
      end

      # Paid and kept: a fully refunded or charged-back order is not money the buyer left behind.
      def customer_paid
        "COALESCE(purchases.price_cents, 0) > 0 AND NOT (#{CUSTOMER_REFUNDED}) AND NOT (#{customer_chargedback})"
      end

      # A YYYY-MM-DD bound is a day in the creator's zone, so a purchase late in their evening counts as that day.
      def customer_day_start(date, zone)
        zone.parse(date.iso8601).beginning_of_day
      end

      def tool_get_subscriptions(args)
        require_scopes!(:view_sales, :account)
        product = find_product!(args["product_id"]) if args["product_id"].present?

        args.fetch("breakdown", "subscriptions") == "churn" ? churn_payload(args, product) : subscriptions_payload(args, product)
      end

      # A creator's subscriptions hang off their products, not off their buyer-side `subscriptions`
      # association, and test subscriptions are excluded to match the subscriber counts they see.
      def subscriptions_payload(args, product)
        subscriptions = Subscription.joins(link: :user).where(users: { id: user.id }).not_is_test_subscription
        subscriptions = subscriptions.where(link_id: product.id) if product
        subscriptions = subscriptions.active if args["status"] == "alive"
        # The complement of the scope the dashboard counts, so a stopped subscription is in exactly one list.
        subscriptions = subscriptions.where.not(id: Subscription.active.select(:id)) if args["status"] == "ended"

        page, next_cursor = paginate(subscriptions.includes(:link, :user, :purchases, :true_original_purchase), args, default: 25, table: "subscriptions")
        { breakdown: "subscriptions", subscriptions: page.map { |subscription| subscription_payload(subscription) }, next_cursor: }.compact
      end

      def subscription_payload(subscription)
        {
          id: subscription.external_id,
          product_id: subscription.link.external_id,
          product_name: subscription.link.name,
          email: subscription_email(subscription),
          status: subscription.status,
          started_at: subscription.created_at.iso8601,
          cancelled_at: subscription.cancelled_at&.iso8601,
          failed_at: subscription.failed_at&.iso8601,
          ended_at: subscription.ended_at&.iso8601,
          failed_payments: subscription.purchases.count { |purchase| purchase.purchase_state == "failed" }
        }
      end

      # `Subscription#email` reads its sender purchase for a gift, which a purchase-less row lacks.
      def subscription_email(subscription)
        return subscription.user.form_email if subscription.user&.form_email.present?

        purchase = subscription.true_original_purchase
        return if purchase.nil?

        return purchase.giftee_email.presence if purchase.is_gift_sender_purchase?

        (subscription.original_purchase || purchase).email
      end

      def churn_payload(args, product)
        timezone = ActiveSupport::TimeZone[user.timezone]
        end_date = args["end_date"] ? parse_date!(args["end_date"], "end_date") : timezone.today
        start_date = args["start_date"] ? parse_date!(args["start_date"], "start_date") : (end_date - SUBSCRIPTION_CHURN_DEFAULT_MONTHS.months).beginning_of_month
        raise Error.new("start_date must not be after end_date", code: -32602) if start_date > end_date
        raise Error.new("The date range cannot exceed #{SUBSCRIPTION_CHURN_MAX_DAYS} days", code: -32602) if (end_date - start_date).to_i >= SUBSCRIPTION_CHURN_MAX_DAYS

        if start_date > timezone.today
          return { breakdown: "churn", start_date: start_date.iso8601, end_date: end_date.iso8601, time_zone: user.timezone, currency: Currency::USD, rows: [] }
        end

        data = CreatorAnalytics::Churn.new(seller: user).generate_data(start_date:, end_date:)
        monthly = data.dig(:data, :current_period, :monthly) || {}
        permalink = product&.unique_permalink
        rows = monthly.filter_map do |month, month_stats|
          stats = permalink ? month_stats[:by_product][permalink] : month_stats[:total]
          next if stats.nil?

          {
            month:,
            subscriber_base: stats[:subscriber_base],
            churned: stats[:churned_customers_count],
            churn_rate_percent: stats[:churn_rate],
            revenue_lost_cents: stats[:revenue_lost_cents]
          }
        end

        # The churn source clamps the range to the seller's first sale and today, so return what it read.
        period = data.dig(:metadata, :current_period) || {}
        {
          breakdown: "churn",
          start_date: period[:start_date] || start_date.iso8601,
          end_date: period[:end_date] || end_date.iso8601,
          time_zone: user.timezone,
          currency: Currency::USD,
          rows:
        }
      rescue Faraday::TimeoutError
        raise ToolError, "Churn took too long for this range. Try a shorter range."
      end

      # The creator is also a buyer: this is the shelf behind "what did I buy, and where is it".
      # Read through the same purchases the library shows, so an assistant cannot see anything the
      # creator cannot open themselves.
      def tool_list_purchases(args)
        # Deliberately not :account, which every older tool still accepts: the creator's own
        # library needs its own consent, not the legacy blanket scope.
        require_scopes!(:view_library)
        purchases = user.purchases.all_success_states.not_is_gift_sender_purchase.not_recurring_charge
          .where.not(link_id: nil)
          .includes(:link, :seller)
          .order(created_at: :desc)
        page, next_cursor = paginate(purchases, args, default: 25, table: "purchases")
        {
          purchases: page.filter_map do |purchase|
            next unless purchase.link

            {
              id: purchase.external_id,
              product_name: purchase.link.name,
              product_permalink: purchase.link.unique_permalink,
              seller_name: purchase.seller.display_name,
              price_cents: purchase.displayed_price_cents,
              currency: purchase.displayed_price_currency_type.to_s,
              purchased_at: purchase.created_at&.iso8601,
              refunded: purchase.refunded?,
              url: "#{PROTOCOL}://#{DOMAIN}/library"
            }
          end,
          next_cursor:
        }.compact
      end

      def tool_list_payouts(args)
        require_scopes!(:view_payouts, :account)
        page, next_cursor = paginate(user.payments, args, default: 10, table: "payments")
        {
          payouts: page.map do |payout|
            {
              id: payout.external_id,
              amount_cents: payout.amount_cents,
              currency: payout.currency,
              state: payout.state,
              created_at: payout.created_at&.iso8601
            }
          end,
          next_cursor:
        }.compact
      end

      # Runs inside the caller's transaction: the update service soft-deletes each member it is not
      # handed, so one unresolvable id must roll back the whole edit, including a bundle just created.
      def bundle_member_attributes(bundle, product_ids)
        raise Error.new("product_ids must name at least one product", code: -32602) if product_ids.empty?

        retained = bundle.bundle_products.alive.includes(:variant).index_by(&:product_id)

        product_ids.map.with_index do |id, position|
          raise Error.new("product_ids[#{position}] must be a non-blank string", code: -32602) unless id.is_a?(String) && id.strip.present?

          product = find_product!(id)
          # The service rewrites the version and quantity of every member it is handed, so a retained
          # member carries over what it already sells. Only a new member takes the defaults, and its
          # first version is what the editor's product picker selects.
          kept = retained[product.id]
          variant = kept&.variant || product.variants_or_skus.first
          { product_id: product.external_id, variant_id: variant&.external_id, quantity: kept&.quantity || DEFAULT_BUNDLE_MEMBER_QUANTITY, position: }
        end
      end

      # Search runs over the same index the discover page uses, so results are what a shopper would
      # see, not a second catalogue that can drift from it.
      def tool_search_products(args)
        require_scopes!(:view_public, :account)
        query = args["query"].to_s.strip
        raise InvalidArguments.new("query is required", code: -32602) if query.empty?
        raise InvalidArguments.new("query is longer than #{SEARCH_QUERY_MAX_LENGTH} characters", code: -32602) if query.length > SEARCH_QUERY_MAX_LENGTH

        # An empty query is not the only way to ask for everything: "*" and friends are operators
        # inside simple_query_string, so the words are all that get sent to the index.
        words = query.gsub(QUERY_OPERATOR_CHARACTERS, " ").squish
        raise InvalidArguments.new("query needs at least one word", code: -32602) if words.blank?

        limit = args["limit"].to_i
        limit = SEARCH_DEFAULT_LIMIT if limit <= 0
        limit = [limit, SEARCH_MAX_LIMIT].min

        # The index lags the database. Only these row states are re-checked here: unpublished, deleted,
        # banned, adult, seller suspended. The rest of Discover eligibility waits for the reindex.
        hits = Link.search(Link.search_options(query: words, size: limit)).records
        # Reload in one query with the Discover card's associations, keeping the index order.
        loaded = Link.where(id: hits.map(&:id)).includes(ProductPresenter::ASSOCIATIONS_FOR_CARD).index_by(&:id)
        products = hits.filter_map { |hit| loaded[hit.id] }
          .select { |product| product.alive? && !product.rated_as_adult? && product.user.present? && !product.user.suspended? }
        {
          products: products.map do |product|
            {
              id: product.external_id,
              name: product.name,
              seller_name: product.user.name_or_username,
              price_cents: product.discounted_price_cents(product.display_price_cents(for_default_duration: true)),
              currency: product.price_currency_type,
              recurring: product.is_recurring_billing?,
              recurrence: product.default_price_recurrence&.recurrence,
              pay_what_you_want: product.has_customizable_price_option?,
              thumbnail_url: product.thumbnail_or_cover_url,
              url: with_mcp_referrer(product.long_url)
            }
          end
        }
      end

      def with_mcp_referrer(url)
        uri = URI.parse(url)
        params = Rack::Utils.parse_nested_query(uri.query.to_s).merge("referrer" => "#{PROTOCOL}://#{DOMAIN}/mcp")
        uri.query = params.to_query
        uri.to_s
      end

      def tool_create_bundle(args)
        require_scopes!(:edit_products, :account)
        name = args["name"].strip
        raise Error.new("name is required", code: -32602) if name.blank?

        price_cents = args["price_cents"]
        raise Error.new("price_cents must be zero or more", code: -32602) if price_cents.negative?

        bundle = user.links.build(
          name:,
          native_type: Link::NATIVE_TYPE_BUNDLE,
          is_bundle: true,
          price_cents:,
          price_currency_type: user.currency_type,
          draft: true,
          purchase_disabled_at: Time.current,
          display_product_reviews: true
        )
        bundle.taxonomy = Taxonomy.find_by(slug: "other")
        ActiveRecord::Base.transaction do
          bundle.save!
          members = bundle_member_attributes(bundle, args["product_ids"])
          Bundle::UpdateProductsService.new(bundle:, products: members).perform
        end
        {
          product: product_payload(bundle.reload),
          bundle_products: bundle_products_payload(bundle),
          message: "Draft bundle saved. It is not for sale until publish_product."
        }
      end

      def tool_update_bundle(args)
        require_scopes!(:edit_products, :account)
        bundle = find_product!(args["id"])
        raise ToolError, "This product is not a bundle. Make one with create_bundle first." if bundle.not_is_bundle?

        ActiveRecord::Base.transaction do
          # Reloads under the lock, then resolves the members here so a retained member keeps the
          # version it already sells even if a concurrent edit just changed it.
          bundle.lock!
          members = bundle_member_attributes(bundle, args["product_ids"])
          Bundle::UpdateProductsService.new(bundle:, products: members).perform
        end
        { product: product_payload(bundle.reload), bundle_products: bundle_products_payload(bundle) }
      end

      def tool_create_discount_code(args)
        require_scopes!(:edit_products, :account)
        code = args["code"].strip
        raise Error.new("code is required", code: -32602) if code.blank?
        product = find_discount_product!(args) if args.key?("product_id")
        attributes = discount_amount_attributes(args, required: true, currency_type: product&.price_currency_type || user.currency_type)
        attributes.merge!(discount_window_attributes(args, default_valid_at: Time.current))
        attributes[:max_purchase_count] = discount_max_purchase_count(args) if args.key?("max_purchase_count")

        offer_code = user.offer_codes.build(code:, universal: product.nil?, products: Array(product), **attributes)
        # offer_codes has no unique index on code, so two overlapping calls from this tool would both
        # pass the uniqueness validation; the seller lock makes the second one see the first row.
        ActiveRecord::Base.transaction do
          User.where(id: user.id).lock.pick(:id)
          save_discount_code!(offer_code)
        end
        { discount_code: discount_code_payload(offer_code) }
      end

      def tool_update_discount_code(args)
        require_scopes!(:edit_products, :account)
        raise Error.new("Pass at least one of #{DISCOUNT_CODE_FIELDS.keys.to_sentence(last_word_connector: ', or ')}", code: -32602) if args.slice(*DISCOUNT_CODE_FIELDS.keys).empty?

        offer_code = find_discount_code!(args)
        # Checkout prices a tiered code from its tiers and ignores amount_percentage.
        raise ToolError, "#{offer_code.code} gives a different discount by how long the buyer has owned the product. Change its amounts in the Gumroad dashboard." if offer_code.tiered? && args.slice("percent_off", "amount_cents").any?

        currency_type = offer_code.currency_type || offer_code.products.first&.price_currency_type || user.currency_type
        offer_code.assign_attributes(discount_amount_attributes(args, required: false, currency_type:))
        offer_code.assign_attributes(discount_window_attributes(args, default_valid_at: offer_code.valid_at || offer_code.created_at))
        offer_code.max_purchase_count = discount_max_purchase_count(args) if args.key?("max_purchase_count")
        save_discount_code!(offer_code)
        { discount_code: discount_code_payload(offer_code) }
      end

      def tool_expire_discount_code(args)
        require_scopes!(:edit_products, :account)
        offer_code = find_discount_code!(args)
        now = Time.current.change(usec: 0)
        return { discount_code: discount_code_payload(offer_code), message: "Already expired." } if offer_code.expires_at.present? && offer_code.expires_at <= now

        # The model requires a start date before the end date, as the editor's "Valid until" does.
        offer_code.valid_at = [offer_code.valid_at || offer_code.created_at, now - DISCOUNT_MIN_VALIDITY_WINDOW].min
        offer_code.expires_at = now
        # Expiring narrows the code to nothing, so the price check, which the current prices can
        # already fail, must not leave the creator unable to end it from here.
        offer_code.save!(context: :expiring)
        { discount_code: discount_code_payload(offer_code), message: "Expired. Buyers can no longer use this code." }
      end

      def find_discount_code!(args)
        code = args["code"].strip
        raise Error.new("code is required", code: -32602) if code.blank?

        if args.key?("product_id")
          product = find_discount_product!(args)
          offer_code = product.offer_codes.alive.where(universal: false, user_id: user.id).find_by(code:)
          raise ToolError, "No discount code #{code} is limited to this product. Omit product_id for a code that covers all products." if offer_code.nil?
        else
          offer_code = user.offer_codes.alive.universal.find_by(code:)
          raise ToolError, "No discount code #{code} covers all products. Pass product_id for a code made for specific products." if offer_code.nil?
        end
        offer_code
      end

      def find_discount_product!(args)
        raise Error.new("product_id must not be blank", code: -32602) if args["product_id"].blank?

        find_product!(args["product_id"])
      end

      # The columns are 4-byte integers; the editor answers an overflow the same way.
      def save_discount_code!(offer_code)
        offer_code.save!
      rescue ActiveModel::RangeError
        raise ToolError, "The value entered is too large. Please enter a smaller number."
      end

      def discount_amount_attributes(args, required:, currency_type:)
        percent, cents = args.values_at("percent_off", "amount_cents")
        raise Error.new("Pass only one of percent_off or amount_cents", code: -32602) if percent && cents
        raise Error.new("Pass one of percent_off or amount_cents", code: -32602) if required && percent.nil? && cents.nil?

        if percent
          raise Error.new("percent_off must be between #{DISCOUNT_PERCENT_RANGE.min} and #{DISCOUNT_PERCENT_RANGE.max}", code: -32602) unless DISCOUNT_PERCENT_RANGE.cover?(percent)

          { amount_percentage: percent, amount_cents: nil, currency_type: nil, once_per_cart: false }
        elsif cents
          raise Error.new("amount_cents must be greater than zero", code: -32602) unless cents.positive?

          { amount_cents: cents, amount_percentage: nil, currency_type: }
        else
          {}
        end
      end

      def discount_window_attributes(args, default_valid_at:)
        attributes = {}
        attributes[:valid_at] = parse_discount_time(args, "valid_at") if args.key?("valid_at")
        if args.key?("expires_at")
          attributes[:expires_at] = parse_discount_time(args, "expires_at")
          attributes[:valid_at] ||= default_valid_at
        end
        attributes
      end

      def parse_discount_time(args, key)
        time = begin
          Time.zone.iso8601(args[key])
        rescue ArgumentError
          raise Error.new("#{key} must be an ISO 8601 time", code: -32602)
        end
        raise Error.new("#{key} must have a year from #{DISCOUNT_YEAR_RANGE.min} to #{DISCOUNT_YEAR_RANGE.max}", code: -32602) unless DISCOUNT_YEAR_RANGE.cover?(time.year)

        time
      end

      def discount_max_purchase_count(args)
        count = args["max_purchase_count"]
        raise Error.new("max_purchase_count must be zero or more", code: -32602) if count.negative?

        count
      end

      def discount_code_payload(offer_code)
        product_ids = offer_code.universal? ? [] : offer_code.products.map(&:external_id)
        {
          id: offer_code.external_id,
          code: offer_code.code,
          # A code made in the editor can cover several products; product_ids lists them all.
          scope: offer_code.universal? ? "universal" : product_ids.first,
          product_ids:,
          # A tiered code's amount_percentage is a placeholder; checkout uses the tiers.
          percent_off: offer_code.tiered? ? nil : offer_code.amount_percentage,
          tiers: offer_code.normalized_ownership_duration_tiers,
          amount_cents: offer_code.amount_cents,
          currency: offer_code.is_cents? ? offer_code.currency_type : nil,
          valid_at: offer_code.valid_at&.iso8601,
          expires_at: offer_code.expires_at&.iso8601,
          max_purchase_count: offer_code.max_purchase_count,
          expired: offer_code.expires_at.present? && offer_code.expires_at <= Time.current
        }
      end

      def product_payload(product)
        {
          id: product.external_id,
          name: product.name,
          price_cents: product.price_cents,
          currency: product.price_currency_type,
          **pricing_payload(product),
          published: product.published?,
          is_bundle: product.is_bundle?,
          url: product.long_url,
          permalink: product.unique_permalink
        }
      end

      # With pay what you want, a price is the minimum and buyers can pay more. A membership keeps
      # this on each tier, priced per billing period, and its product-level flag is not kept in sync.
      def pricing_payload(product)
        unless product.is_tiered_membership
          return { pay_what_you_want: !!product.customizable_price, suggested_price_cents: product.customizable_price? ? product.suggested_price_cents : nil }
        end

        # Built from the loaded associations, so list_products preloads them instead of querying per tier.
        recurrences = product.alive_prices.filter_map { _1.recurrence if _1.is_buy? }
        tier_records = product.tier_categories.flat_map(&:alive_variants).sort_by { [_1.position_in_category.to_i, _1.created_at || Time.at(0)] }
        tiers = tier_records.map do |tier|
          prices = tier.alive_prices.select { _1.is_buy? && recurrences.include?(_1.recurrence) }
            .to_h { [_1.recurrence, { price_cents: _1.price_cents, suggested_price_cents: tier.customizable_price? ? _1.suggested_price_cents : nil }] }
          { id: tier.external_id, name: tier.name, pay_what_you_want: !!tier.customizable_price, prices: }
        end
        # As on the storefront (Link#has_customizable_price_option?), a closed tier counts only when all are closed.
        offered = tier_records.reject(&:closed_to_new_buyers?).presence || tier_records
        # The product-level price is a $0 placeholder that would read as free.
        { price_cents: nil, pay_what_you_want: offered.any?(&:customizable_price?), suggested_price_cents: nil, tiers: }
      end

      # What the product is filed under in Discover: the slug path update_product accepts back, and
      # the name the product editor shows for it.
      def category_payload(product)
        taxonomy = product.taxonomy
        return if taxonomy.nil?

        { path: category_slug_path_for(taxonomy), label: category_label(taxonomy) }
      end

      def category_label(taxonomy)
        Discover::TaxonomyPresenter::TAXONOMY_LABELS[taxonomy.slug].presence || taxonomy.slug
      end

      # Walked from parent_id like taxonomy_paths, not from ancestry_path: the closure table can lag a
      # moved node, and the path we return has to be one update_product accepts back.
      def category_slug_path_for(taxonomy)
        @category_paths ||= taxonomy_paths.each_with_object({}) { |(path, record), paths| paths[record.id] = path }
        @category_paths[taxonomy.id] || taxonomy.slug
      end

      def tool_list_categories(_args)
        require_scopes!(:view_profile, :view_public, :edit_products, :account)
        { categories: taxonomy_paths.sort_by { |path, _| path }.map { |path, taxonomy| { path:, label: category_label(taxonomy) } } }
      end

      # A category is written the way Discover reads it: slug segments from the root down, joined by
      # "/". A bare leaf slug is accepted when the tree holds exactly one, so "blender" works too.
      def resolve_category!(value)
        raise Error.new("category must be a non-blank string", code: -32602) unless value.is_a?(String) && value.strip.present?

        wanted = value.strip.downcase
        paths = taxonomy_paths
        return paths[wanted] if paths.key?(wanted)

        matches = paths.select { |path, _| path.split("/").last == wanted }
        return matches.values.first if matches.size == 1
        raise ToolError, "The category \"#{value}\" matches more than one: #{matches.keys.sort.join(', ')}. Pass the full path." if matches.any?

        # Answering with what the caller probably meant is the difference between one retry and a
        # dead end, because the whole tree is too long to repeat in an error.
        closest = paths.keys.select { |path| path.split("/").last.start_with?(wanted) || path.include?(wanted) }.first(MAX_CATEGORY_SUGGESTIONS)
        message = if closest.any?
          "The category \"#{value}\" was not found. Closest categories: #{closest.join(', ')}."
        else
          "The category \"#{value}\" was not found. A category is a slug path such as \"design/ui-and-web/figma\"."
        end
        raise ToolError, "#{message} Call list_categories for every category."
      end

      # Slug path -> Taxonomy for the whole tree, walked in memory: a few hundred rows, one query,
      # however deep the path the caller sent. Read live, not through Discover::TaxonomyPresenter's
      # hour-long nav cache: update_product writes the id it resolves, which must be in the current tree.
      def taxonomy_paths
        @taxonomy_paths ||= begin
          taxonomies = Taxonomy.all.to_a
          by_id = taxonomies.index_by(&:id)
          paths = {}
          resolve = lambda do |taxonomy|
            paths[taxonomy.id] ||= begin
              parent = by_id[taxonomy.parent_id]
              parent ? "#{resolve.call(parent)}/#{taxonomy.slug}" : taxonomy.slug
            end
          end
          taxonomies.index_by { |taxonomy| resolve.call(taxonomy).downcase }
        end
      end

      def find_product!(id)
        raise Error.new("id is required", code: -32602) if id.blank?

        product = user.links.find_by_external_id(id) || user.links.find_by(unique_permalink: id) || user.links.find_by(custom_permalink: id)
        raise ToolError, "The product was not found." if product.nil? || product.deleted_at.present?

        product
      end

      # Keyset pages over (created_at, id) descending; fetches one extra row to know whether another page exists.
      # The cursor carries created_at in microseconds, not whole seconds, so a timestamp column that ever
      # stores fractional seconds cannot drop rows that fall inside the last row's second.
      def paginate(scope, args, default:, table:)
        limit = limit_for(args, default:)
        if args["cursor"].present?
          at, id = args["cursor"].to_s.split("_", 2)
          raise Error.new("cursor is not valid", code: -32602) unless at.match?(/\A\d+\z/) && id.to_s.match?(/\A\d+\z/)

          time = Time.zone.at(Rational(at.to_i, MICROSECONDS_PER_SECOND))
          raise Error.new("cursor is not valid", code: -32602) if time.year > MAX_DATETIME_YEAR
          scope = scope.where("#{table}.created_at < :t OR (#{table}.created_at = :t AND #{table}.id < :id)", t: time, id: id.to_i)
        end
        rows = scope.order("#{table}.created_at DESC, #{table}.id DESC").limit(limit + 1).to_a
        page = rows.first(limit)
        next_cursor = "#{(page.last.created_at.to_r * MICROSECONDS_PER_SECOND).to_i}_#{page.last.id}" if rows.size > limit
        [page, next_cursor]
      end

      def parse_time!(value, name)
        time = Time.use_zone("UTC") { Time.zone.parse(value) }
        raise ArgumentError if time.nil? || !time.year.between?(0, MAX_DATETIME_YEAR)

        time
      rescue ArgumentError
        raise Error.new("#{name} must be a date or ISO 8601 time", code: -32602)
      end

      def limit_for(args, default:)
        n = args.fetch("limit", default)
        raise Error.new("limit must be between 1 and 50", code: -32602) unless n.between?(1, 50)

        n
      end

      def require_scopes!(*scopes, subject: "This tool")
        token_scopes = token.scopes
        return if scopes.any? { |scope| token_scopes.include?(scope.to_s) }

        message = "#{subject} requires the #{scopes.to_sentence(two_words_connector: ' or ', last_word_connector: ' or ')} scope."
        missing = obtainable_scope(scopes)
        # No challenge for a batch, or when the client registered none of the accepted scopes:
        # either step-up would fail, and a plain error stops the client from retrying.
        raise MissingScope.new(message) if @batch || missing.nil?

        @insufficient_scope = InsufficientScope.new(message, scope: (token_scopes.to_a + [missing]).join(" "))
        raise @insufficient_scope
      end

      # Naming a scope the client cannot request sends it into an invalid_scope error on
      # re-authorization. Must match what authorization accepts.
      def obtainable_scope(scopes)
        registered = token.application && DynamicClientOauth.requestable_scopes(token.application).presence
        scopes.map(&:to_s).find { |scope| registered.nil? || registered.include?(scope) }
      end

      def rpc_error(id, message, code:, data: nil)
        error = { code:, message: }
        error[:data] = data if data
        { jsonrpc: "2.0", id:, error: }
      end
  end
end
