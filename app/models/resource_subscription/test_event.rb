# frozen_string_literal: true

# Builds and delivers a sample payload for one resource subscription. Read-only on purchases and
# subscriptions: it never creates, charges or refunds anything, and posts only to this
# subscription's own post_url (not the fan-out in PostToPingEndpointsWorker, which would reach
# every subscription for the resource).
class ResourceSubscription::TestEvent
  PURCHASE_RESOURCE_NAMES = [
    ResourceSubscription::SALE_RESOURCE_NAME,
    ResourceSubscription::REFUNDED_RESOURCE_NAME,
    ResourceSubscription::DISPUTE_RESOURCE_NAME,
    ResourceSubscription::DISPUTE_WON_RESOURCE_NAME,
  ].freeze

  SAMPLE_TIMESTAMP = "2026-01-01T00:00:00Z"

  attr_reader :resource_subscription

  def initialize(resource_subscription)
    @resource_subscription = resource_subscription
  end

  def deliver
    PostToIndividualPingEndpointWorker.perform_async(
      resource_subscription.post_url,
      payload.deep_stringify_keys,
      resource_subscription.content_type,
      seller.id
    )
  end

  def payload
    @payload ||= (last_event_payload || sample_payload).merge(resource_name:, test: true)
  end

  def from_last_event?
    payload
    @from_last_event
  end

  private
    def seller = resource_subscription.user
    def resource_name = resource_subscription.resource_name

    def last_event_payload
      payload = if PURCHASE_RESOURCE_NAMES.include?(resource_name)
        purchase = last_purchase
        purchase&.payload_for_ping_notification(url_parameters: purchase.url_parameters, resource_name:)
      else
        subscription = last_subscription
        subscription&.payload_for_ping_notification(resource_name:, additional_params: subscription_additional_params(subscription))
      end
      @from_last_event = payload.present?
      payload
    end

    def last_purchase
      case resource_name
      when ResourceSubscription::SALE_RESOURCE_NAME
        seller.sales.where(purchase_state: Purchase::ALL_SUCCESS_STATES_INCLUDING_TEST).order(:id).last
      when ResourceSubscription::REFUNDED_RESOURCE_NAME
        Refund.where(seller_id: seller.id).order(:created_at).last&.purchase
      when ResourceSubscription::DISPUTE_RESOURCE_NAME
        seller.sales.where.not(chargeback_date: nil).order(:chargeback_date).last
      when ResourceSubscription::DISPUTE_WON_RESOURCE_NAME
        Dispute.where(seller_id: seller.id).where.not(won_at: nil).order(:won_at).last&.purchases&.find { _1&.seller_id == seller.id }
      end
    end

    def last_subscription
      scope = Subscription.where(seller_id: seller.id)
      scope = case resource_name
              when ResourceSubscription::CANCELLED_RESOURCE_NAME then scope.where.not(cancelled_at: nil)
              when ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME then scope.where.not(deactivated_at: nil)
              when ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME then scope.where(deactivated_at: nil)
              else scope
      end
      subscription = scope.order(:created_at).last
      # Subscription#payload_for_ping_notification reads the live payment option's price.
      subscription if subscription&.link.present? && subscription.original_purchase.present? && subscription.payment_options.alive.exists?
    end

    def subscription_additional_params(subscription)
      case resource_name
      when ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME
        { restarted_at: Time.current.as_json }
      when ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME
        tier = subscription.tier
        plan = {
          tier: tier && { id: tier.external_id, name: tier.name },
          recurrence: subscription.price.recurrence,
          price_cents: subscription.original_purchase.price_cents,
          quantity: subscription.original_purchase.quantity,
        }
        { type: "upgrade", effective_as_of: Time.current.as_json, old_plan: plan, new_plan: plan }
      else
        {}
      end
    end

    def sample_payload
      PURCHASE_RESOURCE_NAMES.include?(resource_name) ? sample_purchase_payload : sample_subscription_payload
    end

    def sample_purchase_payload
      {
        seller_id: ObfuscateIds.encrypt(seller.id),
        product_id: "sample-product-id",
        product_name: "Sample product",
        permalink: "sample",
        product_permalink: "#{UrlService.domain_with_protocol}/l/sample",
        short_product_id: "sample",
        email: "buyer@example.com",
        price: 1000,
        gumroad_fee: 100,
        currency: "usd",
        quantity: 1,
        discover_fee_charged: false,
        can_contact: true,
        referrer: "direct",
        card: { visual: nil, type: nil, bin: nil, expiry_month: nil, expiry_year: nil },
        order_number: 123_456_789,
        sale_id: "sample-sale-id",
        sale_timestamp: SAMPLE_TIMESTAMP,
        is_gift_receiver_purchase: false,
        refunded: resource_name == ResourceSubscription::REFUNDED_RESOURCE_NAME,
        disputed: resource_name.in?([ResourceSubscription::DISPUTE_RESOURCE_NAME, ResourceSubscription::DISPUTE_WON_RESOURCE_NAME]),
        dispute_won: resource_name == ResourceSubscription::DISPUTE_WON_RESOURCE_NAME,
      }
    end

    def sample_subscription_payload
      payload = {
        subscription_id: "sample-subscription-id",
        product_id: "sample-product-id",
        product_name: "Sample membership",
        user_id: "sample-user-id",
        user_email: "subscriber@example.com",
        purchase_ids: ["sample-sale-id"],
        created_at: SAMPLE_TIMESTAMP,
        charge_occurrence_count: 1,
        recurrence: "monthly",
        free_trial_ends_at: nil,
      }

      case resource_name
      when ResourceSubscription::CANCELLED_RESOURCE_NAME
        payload.merge(cancelled: true, cancelled_at: SAMPLE_TIMESTAMP, cancelled_by_buyer: true)
      when ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME
        payload.merge(ended_at: SAMPLE_TIMESTAMP, ended_reason: "cancelled")
      when ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME
        payload.merge(restarted_at: SAMPLE_TIMESTAMP)
      when ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME
        tier = { id: "sample-tier-id", name: "Sample tier" }
        payload.merge(
          type: "upgrade",
          effective_as_of: SAMPLE_TIMESTAMP,
          old_plan: { tier:, recurrence: "monthly", price_cents: 1000, quantity: 1 },
          new_plan: { tier:, recurrence: "yearly", price_cents: 10_000, quantity: 1 },
        )
      else
        payload
      end
    end
end
