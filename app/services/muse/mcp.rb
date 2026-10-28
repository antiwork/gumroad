# frozen_string_literal: true

module Muse
  # JSON-RPC MCP surface for Meta Muse (and any other MCP client).
  # Tools are a slim, agent-oriented view of the public v2 API — same auth, same records.
  class Mcp
    LEGACY_PROTOCOL_VERSION = "2025-03-26"
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
    # A caller only ever sees their own store, so no result of ours is shareable between callers.
    TOOLS_LIST_CACHE = { ttlMs: 0, cacheScope: "private" }.freeze
    # Nothing in it is caller-specific, but its versions follow the flag, so it is never fresh.
    DISCOVER_CACHE = { ttlMs: 0, cacheScope: "public" }.freeze
    INSTRUCTIONS = "Use these tools for a connected creator's own store: products, sales, and payouts. Confirm with the person before publishing or unpublishing. Buyers still check out on the product URL. This server does not take payment."
    SERVER_INFO = { name: "gumroad", title: "Gumroad", version: "1.0.0" }.freeze

    class Error < StandardError
      attr_reader :code, :data

      def initialize(message, code: -32000, data: nil)
        super(message)
        @code = code
        @data = data
      end
    end

    class ToolError < StandardError; end

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
      ProtocolTelemetry.record(@connector, @protocol_counts)
    end

    def self.discovery(base_url)
      {
        name: "Gumroad",
        description: "Sell digital products. Claude, ChatGPT, Muse, and other MCP clients can list products and sales, draft and edit a product, add a cover image, publish it, and check payouts for a connected creator.",
        website: "https://gumroad.com",
        documentation: "#{base_url}/muse",
        mcp: "#{base_url}/muse/v1/mcp",
        clients: {
          muse: "#{base_url}/muse/v1/mcp",
          claude: "#{base_url}/claude/v1/mcp",
          chatgpt: "#{base_url}/chatgpt/v1/mcp"
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
          capabilities: { tools: { listChanged: false } },
          _meta: { SERVER_INFO_META_KEY => SERVER_INFO },
          instructions: INSTRUCTIONS,
          **DISCOVER_CACHE
        }
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
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: INSTRUCTIONS
        }
      end

      def tools
        [
          tool("get_account", "The connected creator's public profile: name, username, storefront URL, currency.", {}, read_only: true),
          tool("list_products", "List the creator's products (newest first). Returns id, name, price, published state, and URL.", {
                 "limit" => { type: "integer", description: "Max products to return (1-50, default 25)." }
               }, read_only: true),
          tool("get_product", "Fetch one product by id or permalink.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id], read_only: true),
          tool("create_draft_product", "Create a draft digital product. It is not for sale until publish_product runs. Confirm the name and price with the creator first.", {
                 "name" => { type: "string", description: "Product name." },
                 "price_cents" => { type: "integer", description: "Price in minor units (cents for USD). Use 0 for a free product." },
                 "description" => { type: "string", description: "HTML or plain-text description." }
               }, required: %w[name price_cents]),
          tool("update_product", "Change the name, description, or price of an existing product. Pass only the fields to change. The new description replaces the old one. Confirm the changes with the creator first.", {
                 "id" => { type: "string", description: "Product id or permalink." },
                 "name" => { type: "string", description: "New product name." },
                 "description" => { type: "string", description: "New HTML or plain-text description." },
                 "price_cents" => { type: "integer", description: "New price in minor units of the product's currency. Not available for memberships with tiers." }
               }, required: %w[id], destructive: true),
          tool("add_cover", "Add a cover image or video to a product from a public URL. The first cover is the main one on the product page.", {
                 "id" => { type: "string", description: "Product id or permalink." },
                 "url" => { type: "string", description: "Public https URL of an image, or a YouTube or Vimeo link." }
               }, required: %w[id url]),
          tool("publish_product", "Make a draft product purchasable. Confirm with the creator first.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id], destructive: true),
          tool("unpublish_product", "Take a product off sale without deleting it.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id], destructive: true),
          tool("list_sales", "Recent successful sales. Includes buyer email, product, amount, and time.", {
                 "limit" => { type: "integer", description: "Max sales to return (1-50, default 25)." },
                 "email" => { type: "string", description: "Filter by buyer email." }
               }, read_only: true),
          tool("list_payouts", "Recent payouts to the creator's bank or PayPal.", {
                 "limit" => { type: "integer", description: "Max payouts to return (1-50, default 10)." }
               }, read_only: true)
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
        raise Error.new("Unknown tool: #{name}", code: -32602) unless definition

        arguments = params.fetch("arguments", {})
        raise Error.new("arguments must be an object", code: -32602) unless arguments.is_a?(Hash)
        validate_tool_arguments!(definition[:inputSchema], arguments)

        payload = send("tool_#{name}", arguments)
        { content: [{ type: "text", text: JSON.pretty_generate(payload) }], structuredContent: payload }
      rescue ToolError, Link::LinkInvalid, ActiveRecord::RecordInvalid => e
        message = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message
        { content: [{ type: "text", text: message }], isError: true }
      end

      def validate_tool_arguments!(schema, arguments)
        (schema[:required] || []).each do |key|
          raise Error.new("#{key} is required", code: -32602) unless arguments.key?(key)
        end
        arguments.each do |key, value|
          property = schema[:properties][key]
          raise Error.new("Unknown argument: #{key}", code: -32602) unless property

          type = property[:type] == "integer" ? Integer : String
          raise Error.new("#{key} must be a #{property[:type]}", code: -32602) unless value.is_a?(type)
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
        products = user.products.visible.order(created_at: :desc, id: :desc).limit(limit_for(args, default: 25))
          .includes(:alive_prices, tier_categories: { alive_variants: :alive_prices })
        { products: products.map { |product| product_payload(product) } }
      end

      def tool_get_product(args)
        require_scopes!(:view_profile, :view_public, :edit_products, :account)
        product = find_product!(args["id"])
        details = { description: product.description }
        # The same rule as the public API: sales figures need a sales scope.
        details.merge!(sales_count: product.successful_sales_count, sales_usd_cents: product.total_usd_cents) if (token.scopes.to_a & %w[view_sales account]).any?
        { product: product_payload(product).merge(details) }
      end

      def tool_create_draft_product(args)
        require_scopes!(:edit_products, :account)
        name = args["name"].strip
        raise Error.new("name is required", code: -32602) if name.blank?

        price_cents = args["price_cents"]
        raise Error.new("price_cents must be zero or more", code: -32602) if price_cents.negative?

        product = user.links.build(
          name:,
          description: args["description"].to_s,
          native_type: Link::NATIVE_TYPE_DIGITAL,
          price_cents:,
          price_currency_type: user.currency_type,
          draft: true,
          purchase_disabled_at: Time.current,
          display_product_reviews: true
        )
        product.taxonomy = Taxonomy.find_by(slug: "other")
        product.save!
        { product: product_payload(product), message: "Draft saved. It is not for sale until publish_product." }
      end

      def tool_update_product(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        changes = args.slice("name", "description", "price_cents")
        raise Error.new("Pass at least one of name, description, or price_cents", code: -32602) if changes.empty?

        # `price_cents=` saves its Price row at once, so a later validation failure must roll it back.
        ActiveRecord::Base.transaction do
          if changes.key?("name")
            name = changes["name"].strip
            raise Error.new("name must not be blank", code: -32602) if name.blank?

            product.name = name
          end
          if changes.key?("price_cents")
            raise Error.new("price_cents must be zero or more", code: -32602) if changes["price_cents"].negative?
            # Tier prices live on the variants; the product-level price is a placeholder.
            raise ToolError, "Price cannot be changed for a membership with tiers. Edit the tier prices in the product editor." if product.is_tiered_membership

            product.price_cents = changes["price_cents"]
          end
          if changes.key?("description")
            product.description = SaveContentUpsellsService.new(seller: user, content: changes["description"], old_content: product.description).from_html
          end
          product.save!
        end
        result = { product: product_payload(product.reload).merge(description: product.description) }
        # A lower price can push an existing discount below the minimum; the editor warns rather than refuses.
        if changes.key?("price_cents")
          invalid_codes = product.product_and_universal_offer_codes.reject { _1.is_amount_valid?(product) }.map(&:code)
          result[:warning] = "These discount codes would discount this product below #{product.min_price_formatted}: #{invalid_codes.join(', ')}. Edit or delete them in Gumroad." if invalid_codes.any?
        end
        result
      end

      def tool_add_cover(args)
        require_scopes!(:edit_products, :account)
        product = find_product!(args["id"])
        cover = product.asset_previews.build
        begin
          cover.url = args["url"]
        rescue *INTERNET_EXCEPTIONS
          raise ToolError, "Could not fetch an image from that URL. Use a public https link to the image file."
        end
        cover.analyze_file
        unless cover.save
          cover.file.blob&.purge if cover.file.attached?
          raise ToolError, cover.errors.full_messages.to_sentence
        end

        covers = product.display_asset_previews.reload
        { product: product_payload(product), covers: covers.map { |preview| { id: preview.guid, url: preview.url, type: preview.display_type } } }
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
        sales = user.sales.successful_or_preorder_authorization_successful.order(created_at: :desc)
        sales = sales.where(email: args["email"].to_s.strip) if args["email"].present?
        sales = sales.limit(limit_for(args, default: 25))
        {
          sales: sales.map do |sale|
            {
              id: sale.external_id,
              email: sale.email,
              product_id: sale.link.external_id,
              product_name: sale.link.name,
              price_cents: sale.price_cents,
              currency: Currency::USD,
              created_at: sale.created_at.iso8601,
              refunded: sale.refunded?,
              chargedback: sale.chargedback?
            }
          end
        }
      end

      def tool_list_payouts(args)
        require_scopes!(:view_payouts, :account)
        payouts = user.payments.order(created_at: :desc).limit(limit_for(args, default: 10))
        {
          payouts: payouts.map do |payout|
            {
              id: payout.external_id,
              amount_cents: payout.amount_cents,
              currency: payout.currency,
              state: payout.state,
              created_at: payout.created_at&.iso8601
            }
          end
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
        tier_records = product.tier_categories.flat_map(&:alive_variants).sort_by { [_1.position_in_category.to_i, _1.created_at] }
        tiers = tier_records.map do |tier|
          prices = tier.alive_prices.select { _1.is_buy? && recurrences.include?(_1.recurrence) }
            .to_h { [_1.recurrence, { price_cents: _1.price_cents, suggested_price_cents: tier.customizable_price? ? _1.suggested_price_cents : nil }] }
          { name: tier.name, pay_what_you_want: !!tier.customizable_price, prices: }
        end
        # As on the storefront (Link#has_customizable_price_option?), a closed tier counts only when all are closed.
        offered = tier_records.reject(&:closed_to_new_buyers?).presence || tier_records
        # The product-level price is a $0 placeholder that would read as free.
        { price_cents: nil, pay_what_you_want: offered.any?(&:customizable_price?), suggested_price_cents: nil, tiers: }
      end

      def find_product!(id)
        raise Error.new("id is required", code: -32602) if id.blank?

        product = user.links.find_by_external_id(id) || user.links.find_by(unique_permalink: id) || user.links.find_by(custom_permalink: id)
        raise ToolError, "The product was not found." if product.nil? || product.deleted_at.present?

        product
      end

      def limit_for(args, default:)
        n = args.fetch("limit", default)
        raise Error.new("limit must be between 1 and 50", code: -32602) unless n.between?(1, 50)

        n
      end

      def require_scopes!(*scopes)
        token_scopes = token.scopes
        return if scopes.any? { |scope| token_scopes.include?(scope.to_s) }

        message = "This tool requires the #{scopes.to_sentence(two_words_connector: ' or ', last_word_connector: ' or ')} scope."
        missing = obtainable_scope(scopes)
        # No challenge for a batch, or when the client registered none of the accepted scopes:
        # either step-up would fail, and a plain error stops the client from retrying.
        raise Error.new(message) if @batch || missing.nil?

        @insufficient_scope = InsufficientScope.new(message, scope: (token_scopes.to_a + [missing]).join(" "))
        raise @insufficient_scope
      end

      # A dynamic client may have registered only some of the scopes a tool accepts; naming one
      # it never registered sends it into an invalid_scope error on re-authorization.
      def obtainable_scope(scopes)
        registered = token.application&.scopes.presence
        scopes.map(&:to_s).find { |scope| registered.nil? || registered.include?(scope) }
      end

      def rpc_error(id, message, code:, data: nil)
        error = { code:, message: }
        error[:data] = data if data
        { jsonrpc: "2.0", id:, error: }
      end
  end
end
