# frozen_string_literal: true

module Muse
  # JSON-RPC MCP surface for Meta Muse (and any other MCP client).
  # Tools are a slim, agent-oriented view of the public v2 API — same auth, same records.
  class Mcp
    PROTOCOL_VERSION = "2025-03-26"
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

    def initialize(user:, token:)
      @user = user
      @token = token
    end

    def handle(body)
      if body.is_a?(Array)
        return rpc_error(nil, "Invalid Request", code: -32600) if body.empty?

        return body.filter_map { |message| handle_message(message) }.presence
      end

      handle_message(body)
    end

    def self.discovery(base_url)
      {
        name: "Gumroad",
        description: "Sell digital products. Claude, ChatGPT, Muse, and other MCP clients can list products and sales, draft a product, publish it, and check payouts for a connected creator.",
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
          scopes: %w[view_profile view_sales edit_products view_payouts account]
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
        scopes_supported: Doorkeeper.configuration.public_scopes.map(&:to_s),
        code_challenge_methods_supported: %w[S256 plain]
      }
    end

    def self.protected_resource_metadata(base_url, resource_path: "/muse/v1/mcp")
      {
        resource: "#{base_url}#{resource_path}",
        authorization_servers: [base_url],
        bearer_methods_supported: ["header"],
        scopes_supported: Doorkeeper.configuration.public_scopes.map(&:to_s)
      }
    end

    private
      attr_reader :user, :token

      def handle_message(body)
        return rpc_error(nil, "Invalid Request", code: -32600) unless body.is_a?(Hash)

        id = valid_id?(body["id"]) ? body["id"] : nil
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

        result = case method
                 when "initialize" then initialize_result
                 when "notifications/initialized", "notifications/cancelled" then nil
                 when "ping" then {}
                 when "tools/list" then { tools: tools }
                 when "tools/call" then call_tool(params)
                 else
                   raise Error.new("Method not found: #{method}", code: -32601)
        end
        notification ? nil : { jsonrpc: "2.0", id:, result: }
      rescue Error => e
        notification ? nil : rpc_error(id, e.message, code: e.code, data: e.data)
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
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: SERVER_INFO,
          instructions: "Gumroad is where independent creators sell digital products. Use these tools for a connected creator's own store: products, sales, and payouts. Confirm with the person before publishing, refunding, or changing prices. Buyers checking out still use the product URL — Muse's browser handles that."
        }
      end

      def tools
        [
          tool("get_account", "The connected creator's public profile: name, username, storefront URL, currency.", {}),
          tool("list_products", "List the creator's products (newest first). Returns id, name, price, published state, and URL.", {
                 "limit" => { type: "integer", description: "Max products to return (1-50, default 25)." }
               }),
          tool("get_product", "Fetch one product by id or permalink.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id]),
          tool("create_draft_product", "Create a draft digital product. It is not for sale until publish_product runs. Confirm the name and price with the creator first.", {
                 "name" => { type: "string", description: "Product name." },
                 "price_cents" => { type: "integer", description: "Price in minor units (cents for USD). Use 0 for a free product." },
                 "description" => { type: "string", description: "HTML or plain-text description." }
               }, required: %w[name price_cents]),
          tool("publish_product", "Make a draft product purchasable. Confirm with the creator first.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id]),
          tool("unpublish_product", "Take a product off sale without deleting it.", {
                 "id" => { type: "string", description: "Product id or permalink." }
               }, required: %w[id]),
          tool("list_sales", "Recent successful sales. Includes buyer email, product, amount, and time.", {
                 "limit" => { type: "integer", description: "Max sales to return (1-50, default 25)." },
                 "email" => { type: "string", description: "Filter by buyer email." }
               }),
          tool("list_payouts", "Recent payouts to the creator's bank or PayPal.", {
                 "limit" => { type: "integer", description: "Max payouts to return (1-50, default 10)." }
               })
        ]
      end

      def tool(name, description, properties, required: [])
        schema = { type: "object", properties:, additionalProperties: false }
        schema[:required] = required if required.any?
        { name:, title: name.humanize, description:, inputSchema: schema }
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
        { products: products.map { |product| product_payload(product) } }
      end

      def tool_get_product(args)
        require_scopes!(:view_profile, :view_public, :edit_products, :account)
        { product: product_payload(find_product!(args["id"])) }
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
          published: product.published?,
          url: product.long_url,
          permalink: product.unique_permalink
        }
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

        raise Error.new("This tool requires the #{scopes.to_sentence(last_word_connector: ' or ')} scope.")
      end

      def rpc_error(id, message, code:, data: nil)
        error = { code:, message: }
        error[:data] = data if data
        { jsonrpc: "2.0", id:, error: }
      end
  end
end
