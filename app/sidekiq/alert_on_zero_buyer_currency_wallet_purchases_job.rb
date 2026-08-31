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
    return reset_zero_window unless buyer_currency_wallets_enabled?

    recent_count = recent_wallet_presentment_purchase_count
    return reset_zero_window if recent_count.positive?

    first_seen_at = zero_volume_first_seen_at
    if first_seen_at.blank?
      record_zero_volume_started
      return
    end

    return if first_seen_at > ZERO_VOLUME_WINDOW.ago
    return if recently_alerted?

    InternalNotificationWorker.perform_async(ALERT_ROOM, "Buyer-currency wallet purchases at zero", message_for(first_seen_at))
    record_alerted
  end

  private
    def buyer_currency_wallets_enabled?
      return true if Feature.active?(Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME)

      flipper_feature = Flipper[Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME]
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

    def recent_wallet_presentment_purchase_count
      Purchase.successful
        .joins(:purchase_presentment, :purchase_wallet_type)
        .where("purchases.created_at >= ?", ZERO_VOLUME_WINDOW.ago)
        .where(purchase_wallet_types: { wallet_type: WALLET_TYPES })
        .count
    end

    def zero_volume_first_seen_at
      timestamp = $redis.get(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at)
      Time.at(timestamp.to_i) if timestamp.present?
    end

    def record_zero_volume_started
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at, Time.current.to_i)
    end

    def reset_zero_window
      $redis.del(RedisKey.buyer_currency_wallet_presentment_zero_first_seen_at)
      $redis.del(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)
    end

    def recently_alerted?
      timestamp = $redis.get(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at)
      timestamp.present? && Time.at(timestamp.to_i) > ALERT_THROTTLE.ago
    end

    def record_alerted
      $redis.set(RedisKey.buyer_currency_wallet_presentment_zero_alerted_at, Time.current.to_i, ex: ALERT_THROTTLE.to_i)
    end

    def message_for(first_seen_at)
      [
        "Buyer-currency wallet purchases have stayed at 0 for #{((Time.current - first_seen_at) / 1.hour).floor} hours while buyer_currency_wallets is enabled.",
        "",
        "Expected baseline before the Aug 16 regression was about 370–420 wallet purchases with presentment rows per day. Check antiwork/gumroad-private#2326 and the buyer_currency_wallets flag before closing the incident.",
      ].join("\n")
    end
end
