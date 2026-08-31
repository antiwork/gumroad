# frozen_string_literal: true

# Reports when the buyer-currency wallet lane is enabled but no Apple Pay / Google Pay purchase
# lands with a presentment row for a full day (gumroad-private#2326).
class AlertOnZeroBuyerCurrencyWalletPurchasesJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  WALLET_TYPES = %w[apple_pay google_pay].freeze
  ZERO_VOLUME_WINDOW = 24.hours
  ALERT_THROTTLE = 24.hours
  ALERT_ROOM = "agent_reports"

  def perform
    return reset_alert_throttle unless wallet_lane_enabled?
    return reset_alert_throttle if recent_wallet_presentment_purchase_exists?
    return unless claim_alert_throttle

    InternalNotificationWorker.perform_async(ALERT_ROOM, "Buyer-currency wallet purchases at zero", message_for(last_wallet_presentment_purchase_at))
  end

  private
    # Checkout::BuyerCurrencyEligibility.wallets_enabled? ANDs both flags per seller. Either
    # flag fully off means wallets are intentionally dark, so a zero-volume day is not an incident.
    def wallet_lane_enabled?
      feature_rollout_present?(Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME) &&
        feature_rollout_present?(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)
    end

    def feature_rollout_present?(feature_name)
      return true if Feature.active?(feature_name)

      flipper_feature = Flipper[feature_name]
      flipper_value_present?(flipper_feature, :percentage_of_actors_value) ||
        flipper_value_present?(flipper_feature, :percentage_of_time_value) ||
        flipper_value_present?(flipper_feature, :actors_value) ||
        flipper_value_present?(flipper_feature, :groups_value)
    end

    def flipper_value_present?(flipper_feature, method_name)
      return false unless flipper_feature.respond_to?(method_name)

      value = flipper_feature.public_send(method_name)
      value.respond_to?(:any?) ? value.any? : value.to_i.positive?
    end

    def wallet_presentment_purchases
      Purchase.successful
        .joins(:purchase_presentment, :purchase_wallet_type)
        .where(purchase_wallet_types: { wallet_type: WALLET_TYPES })
    end

    def recent_wallet_presentment_purchase_exists?
      wallet_presentment_purchases.where("purchases.created_at >= ?", ZERO_VOLUME_WINDOW.ago).exists?
    end

    # Newest id rather than MAX(created_at), which has no supporting index and can scan the table.
    # Rows are only inserted at checkout, so the newest id carries the newest timestamp.
    def last_wallet_presentment_purchase_at
      wallet_presentment_purchases.order(id: :desc).limit(1).pick(:created_at)
    end

    def reset_alert_throttle
      $redis.del(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)
    end

    # Claim before enqueue so overlapping hourly (or manual) runs cannot both notify.
    def claim_alert_throttle
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at, Time.current.to_i, nx: true, ex: ALERT_THROTTLE.to_i)
    end

    def message_for(last_purchase_at)
      [
        headline(last_purchase_at),
        "",
        "Expected baseline before the Aug 16 regression was about 370–420 wallet purchases with presentment rows per day. Check antiwork/gumroad-private#2326 and the payment_element_wallets plus buyer_currency_wallets flags before closing the incident.",
      ].join("\n")
    end

    def headline(last_purchase_at)
      return "No buyer-currency wallet purchase with a presentment row has ever been recorded while the buyer-currency wallet lane is enabled." if last_purchase_at.blank?

      hours = ((Time.current - last_purchase_at) / 1.hour).floor
      "No buyer-currency wallet purchase with a presentment row has been recorded in #{hours} hours while the buyer-currency wallet lane is enabled. The last one was at #{last_purchase_at.utc.strftime('%Y-%m-%d %H:%M UTC')}."
    end
end
