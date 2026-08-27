# frozen_string_literal: true

module Post::Caching
  # Engagement counters live in the _ddb namespace so pre-cutover Mongo
  # cache values cannot leak back onto the dashboard.
  def key_for_cache(key)
    "#{key}_for_installment_#{id}_ddb"
  end

  def invalidate_cache(key)
    @dynamo_engagement_summary = nil
    Rails.cache.delete(key_for_cache(key))
  end
end
