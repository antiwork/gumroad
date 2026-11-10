# frozen_string_literal: true

module Mcp
  # events/list, events/subscribe and events/unsubscribe, with webhook delivery only. The standard
  # (SEP-3415) is still a draft, so the capability key and the callback error code follow OpenAI's
  # document for ChatGPT, the one client that subscribes today.
  class Events
    METHODS = %w[events/list events/subscribe events/unsubscribe].freeze
    INVALID_PARAMS = -32602
    CALLBACK_ENDPOINT_ERROR = -32015
    WEBHOOK = "webhook"
    MILLISECONDS_PER_SECOND = 1000
    DESCRIPTORS = [
      {
        name: McpEventSubscription::SALE_CREATED,
        description: "Fires when one of the creator's products sells, free downloads included. The payload identifies the sale; list_sales gives the buyer's email and the amounts after fees.",
        delivery: [WEBHOOK],
        inputSchema: { type: "object", properties: {}, additionalProperties: false },
        payloadSchema: {
          type: "object",
          properties: {
            sale_id: { type: "string", description: "The sale's id, as list_sales gives it." },
            product_id: { type: "string", description: "The product's id, as list_products gives it." },
            product_name: { type: "string" },
            price_cents: { type: "integer", description: "Price before fees, in minor units of USD." },
            currency: { type: "string", description: "Always usd." },
            created_at: { type: "string", format: "date-time" }
          },
          required: %w[sale_id product_id product_name price_cents currency created_at],
          additionalProperties: false
        }
      }
    ].freeze

    # The two callables are the server's own scope and argument checks, so a caller gets the same
    # step-up challenge and the same errors as from a tool.
    def initialize(user:, token:, authorize_sales:, validate_arguments:)
      @user = user
      @token = token
      @authorize_sales = authorize_sales
      @validate_arguments = validate_arguments
    end

    def call(method, params)
      case method
      when "events/list" then { events: DESCRIPTORS }
      when "events/subscribe" then subscribe(params)
      when "events/unsubscribe" then unsubscribe(params)
      end
    end

    private
      attr_reader :user, :token

      def subscribe(params)
        descriptor = DESCRIPTORS.find { _1[:name] == params["name"] }
        raise invalid("Unknown event: #{params["name"]}. events/list names the events this server publishes.") unless descriptor

        arguments = object!(params["arguments"], "arguments")
        @validate_arguments.call(descriptor[:inputSchema], arguments)
        delivery = delivery!(params["delivery"])
        raise invalid("delivery.secret must be a string") unless delivery["secret"].is_a?(String)

        ttl_ms = params["ttlMs"]
        raise invalid("ttlMs must be an integer or null") unless ttl_ms.nil? || ttl_ms.is_a?(Integer)

        attributes = { user:, oauth_application:, event_name: descriptor[:name], arguments:, callback_url: delivery["url"], secret: delivery["secret"] }
        # A live subscription to the URL means the connection passed its challenge already.
        unless McpEventSubscription.live.exists?(user_id: user.id, oauth_application_id: token.application_id, callback_url: delivery["url"])
          candidate = McpEventSubscription.new(attributes).tap(&:validate!)
        end
        # After every check that needs no permission, so a malformed call does not ask the creator for more access.
        @authorize_sales.call
        verify!(candidate) if candidate
        subscription = store!(attributes, ttl: ttl_ms && ttl_ms / MILLISECONDS_PER_SECOND)
        # No event type here replays, so there is no cursor to give and nothing was skipped.
        { id: subscription.public_id, refreshBefore: subscription.expires_at.utc.iso8601, cursor: nil, truncated: false }
      rescue ActiveRecord::RecordInvalid => e
        raise invalid(e.record.errors.full_messages.to_sentence)
      end

      # Idempotent: a key with no subscription behind it is already in the state the caller asked for.
      def unsubscribe(params)
        raise invalid("name must be a string") unless params["name"].is_a?(String)

        key_digest = McpEventSubscription.key_digest_for(
          user_id: user.id,
          oauth_application_id: token.application_id,
          event_name: params["name"],
          arguments: object!(params["arguments"], "arguments"),
          callback_url: delivery!(params["delivery"])["url"]
        )
        McpEventSubscription.where(key_digest:).delete_all
        {}
      end

      def verify!(candidate)
        EventWebhook.verify!(candidate)
      rescue EventWebhook::CallbackError => e
        raise Server::Error.new(e.message, code: CALLBACK_ENDPOINT_ERROR, data: { reason: e.reason })
      end

      # A revocation updates this token's row before it deletes the connection's subscriptions, and
      # the challenge before this can take seconds. Holding the row until the insert commits means
      # the revocation either deletes what is stored here, or comes first and is refused here.
      def store!(attributes, ttl:)
        McpEventSubscription.transaction do
          raise Server::Error.new("Access to this account was revoked.") if Doorkeeper::AccessToken.lock.find(token.id).revoked?

          McpEventSubscription.subscribe!(**attributes, ttl:)
        end
      end

      def oauth_application
        # The token's own association is Doorkeeper's base class, which the subscription does not accept.
        @oauth_application ||= OauthApplication.find(token.application_id)
      end

      def delivery!(delivery)
        raise invalid("delivery must be an object") unless delivery.is_a?(Hash)
        raise invalid("delivery.mode must be #{WEBHOOK}: no other delivery is offered") unless delivery.fetch("mode", WEBHOOK) == WEBHOOK
        raise invalid("delivery.url must be a string") unless delivery["url"].is_a?(String)

        delivery
      end

      def object!(value, field)
        return {} if value.nil?
        raise invalid("#{field} must be an object") unless value.is_a?(Hash)

        value
      end

      def invalid(message)
        Server::Error.new(message, code: INVALID_PARAMS)
      end
  end
end
