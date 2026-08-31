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

    enqueue_alert(last_wallet_presentment_purchase_at)
  end

  private
    def wallet_lane_enabled?
      feature_rollouts_overlap?(
        Checkout::BuyerCurrencyEligibility::PAYMENT_ELEMENT_WALLETS_FEATURE_NAME,
        Checkout::BuyerCurrencyEligibility::WALLETS_FEATURE_NAME,
      )
    end

    def feature_rollouts_overlap?(first_feature_name, second_feature_name)
      return false unless feature_rollout_present?(first_feature_name) && feature_rollout_present?(second_feature_name)
      return true if broad_rollout?(first_feature_name) && broad_rollout?(second_feature_name)
      return true if broad_rollout_covers_targeted_actors?(first_feature_name, second_feature_name)
      return true if broad_rollout_covers_targeted_actors?(second_feature_name, first_feature_name)

      targeted_rollouts_overlap?(first_feature_name, second_feature_name)
    end

    def feature_rollout_present?(feature_name)
      broad_rollout?(feature_name) || targeted_actor_values(feature_name).any? || targeted_group_values(feature_name).any?
    end

    def broad_rollout?(feature_name)
      Feature.active?(feature_name) || percentage_rollout?(feature_name)
    end

    def percentage_rollout?(feature_name)
      flipper_feature = Flipper[feature_name]
      flipper_numeric_value(flipper_feature, :percentage_of_actors_value).positive? ||
        flipper_numeric_value(flipper_feature, :percentage_of_time_value).positive?
    end

    def flipper_numeric_value(flipper_feature, method_name)
      return 0 unless flipper_feature.respond_to?(method_name)

      flipper_feature.public_send(method_name).to_i
    end

    def broad_rollout_covers_targeted_actors?(broad_feature_name, targeted_feature_name)
      users_for_actor_values(targeted_actor_values(targeted_feature_name)).any? { Feature.active?(broad_feature_name, _1) } ||
        targeted_group_values(targeted_feature_name).any?
    end

    def targeted_rollouts_overlap?(first_feature_name, second_feature_name)
      users_for_actor_values(targeted_actor_values(first_feature_name) | targeted_actor_values(second_feature_name)).any? do |user|
        Checkout::BuyerCurrencyEligibility.wallets_enabled?(user)
      end || (targeted_group_values(first_feature_name) & targeted_group_values(second_feature_name)).any?
    end

    def targeted_actor_values(feature_name)
      values_for(feature_name, :actors_value)
    end

    def targeted_group_values(feature_name)
      values_for(feature_name, :groups_value)
    end

    def values_for(feature_name, method_name)
      flipper_feature = Flipper[feature_name]
      return [] unless flipper_feature.respond_to?(method_name)

      Array(flipper_feature.public_send(method_name)).map(&:to_s)
    end

    def users_for_actor_values(actor_values)
      user_ids = actor_values.filter_map { _1[/\AUser;(\d+)\z/, 1] }.map(&:to_i)
      User.where(id: user_ids)
    end

    def wallet_presentment_purchases
      Purchase.successful
        .joins(:purchase_presentment, :purchase_wallet_type)
        .where(purchase_wallet_types: { wallet_type: WALLET_TYPES })
        .where.not(purchase_presentments: { presentment_currency: Currency::USD })
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

    def enqueue_alert(last_purchase_at)
      InternalNotificationWorker.perform_async(ALERT_ROOM, "Buyer-currency wallet purchases at zero", message_for(last_purchase_at))
    rescue StandardError
      reset_alert_throttle
      raise
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
