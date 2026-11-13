# frozen_string_literal: true

module MetaConversions
  # The buyer-side values Meta needs that only the checkout request holds. Saved for seven days so
  # the sender can still read them once the purchase has succeeded.
  module PurchaseContext
    TTL = 7.days.to_i

    module_function

    def save_for(purchases, user_agent:, base_url:)
      purchases.each do |purchase|
        next unless Eligibility.seller_skip_reason(purchase.seller).nil?

        $redis.setex(
          RedisKey.meta_conversions_purchase_context(purchase.id),
          TTL,
          { user_agent:, base_url: }.to_json
        )
      end
    end

    def fetch(purchase_id)
      raw = $redis.get(RedisKey.meta_conversions_purchase_context(purchase_id))
      return if raw.blank?

      context = JSON.parse(raw)
      { user_agent: context["user_agent"], base_url: context["base_url"] }
    end
  end
end
