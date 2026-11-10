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
    # Long enough for a ping that waited out a busy queue. A resend within it reaches the client as
    # a duplicate it can drop.
    NEW_ORDER_WINDOW = 1.day
    DESCRIPTORS = [
      {
        name: McpEventSubscription::SALE_CREATED,
        description: "Fires once for each new order that list_sales shows: free downloads and membership renewals count, a gift or a bundle counts once, a preorder counts when the buyer places it, and test purchases do not count. The payload identifies the sale; list_sales gives the buyer's email and the amounts after fees.",
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

    class << self
      # Queues one delivery for each live subscription of the seller. Called for every sale ping, so
      # a seller with no subscription costs one indexed query.
      def publish_sale(purchase)
        subscription_ids = McpEventSubscription.live.where(user_id: purchase.seller_id, event_name: McpEventSubscription::SALE_CREATED).ids
        return if subscription_ids.empty?

        sale = new_order(purchase)
        return if sale.nil? || !Feature.active?(:mcp_events, purchase.seller)

        event = sale_created(sale)
        DeliverEventJob.perform_bulk(subscription_ids.map { [_1, event] })
      end

      # String keys: it travels as Sidekiq job arguments. `data` is the sale.created payloadSchema above.
      def sale_created(purchase)
        {
          # Stable per sale, so a ping sent again for the same sale reaches the client as a duplicate it can drop.
          "eventId" => "evt_sale_#{ObfuscateIds.encrypt(purchase.id, padding: false)}",
          "name" => McpEventSubscription::SALE_CREATED,
          "timestamp" => purchase.created_at.utc.iso8601,
          "data" => {
            "sale_id" => purchase.external_id,
            "product_id" => purchase.link.external_id,
            "product_name" => purchase.link.name,
            "price_cents" => purchase.price_cents,
            "currency" => Currency::USD,
            "created_at" => purchase.created_at.utc.iso8601
          },
          "cursor" => nil
        }
      end

      private
        # The purchase list_sales shows for a pinged sale, or nil when the ping is not a new order.
        def new_order(purchase)
          # The giftee's purchase is the one that pings, but list_sales shows the gifter's, which was paid.
          purchase = purchase.gift_received&.gifter_purchase if purchase.is_gift_receiver_purchase
          return if purchase.nil? || !Purchase::CHARGED_SUCCESS_STATES.include?(purchase.purchase_state)
          # Each of these belongs to an order that already fired: a bundle's member rows, and the
          # charge a preorder makes at release.
          return if purchase.is_bundle_product_purchase || (purchase.preorder_id.present? && !purchase.is_preorder_authorization)
          # A seller can resend a ping from the dashboard long after the sale.
          return if (purchase.succeeded_at || purchase.created_at) < NEW_ORDER_WINDOW.ago

          purchase
        end
    end

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
        # Checked here as well as by the model: a refresh skips the model's checks until after the scope check.
        raise invalid("delivery.secret #{McpEventSubscription::SECRET_ERROR}") unless McpEventSubscription.valid_secret?(delivery["secret"])

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
          # The seller before the token, the order account closure takes them in.
          McpEventSubscription.lock_seller!(user.id)
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
