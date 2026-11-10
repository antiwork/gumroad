# frozen_string_literal: true

class Mcp::DeliverEventJob
  include Sidekiq::Job
  # A retry is enqueued below, not raised: each attempt needs a new timestamp and signature, and an
  # endpoint that is down is not an error of ours. The low queue, because a callback host is outside
  # our control and one that hangs must not hold back other work.
  sidekiq_options retry: 0, queue: :low

  # Four attempts in under eleven minutes. An event still not delivered then is dropped.
  RETRY_DELAYS = [30.seconds, 2.minutes, 8.minutes].freeze
  # How a receiver says "do not send this event again". Neither status ends the subscription.
  NON_RETRYABLE_STATUSES = [410, 413].freeze

  def perform(subscription_id, event, attempt = 0)
    # The primary: a refresh can replace the secret, and an unsubscribe or a revocation can land, moments before.
    subscription = ApplicationRecord.connected_to(role: :writing) { McpEventSubscription.live.find_by(id: subscription_id) }
    return if subscription.nil?

    unless ApplicationRecord.connected_to(role: :writing) { subscription.access_granted? }
      # The secret has no use now. The client subscribes again once it holds a token with the scope.
      subscription.delete
      log(subscription_id, event, attempt, "access_revoked")
      return
    end

    response = Mcp::EventWebhook.post(subscription, message_id: event["eventId"], payload: event)
    log(subscription_id, event, attempt, "http_#{response.status}")
    retry_later(subscription_id, event, attempt) unless response.success? || NON_RETRYABLE_STATUSES.include?(response.status)
  rescue Mcp::EventWebhook::CallbackError => e
    log(subscription_id, event, attempt, e.reason)
    retry_later(subscription_id, event, attempt) if e.retryable?
  end

  private
    def retry_later(subscription_id, event, attempt)
      delay = RETRY_DELAYS[attempt]
      self.class.perform_in(delay, subscription_id, event, attempt + 1) if delay
    end

    def log(subscription_id, event, attempt, outcome)
      Rails.logger.info("mcp_event_delivery subscription_id=#{subscription_id} event=#{event["name"]} attempt=#{attempt + 1} outcome=#{outcome}")
    end
end
