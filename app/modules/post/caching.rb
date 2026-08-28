# frozen_string_literal: true

module Post::Caching
  # Default keys stay in the _ddb namespace so pre-cutover Mongo cache values
  # cannot leak back onto the dashboard. dynamodb_reads: false still names the
  # unsuffixed legacy key so event handlers can delete it (Memcached cannot
  # bulk-delete).
  def key_for_cache(key, dynamodb_reads: true)
    "#{key}_for_installment_#{id}#{dynamodb_reads ? "_ddb" : ""}"
  end

  def invalidate_cache(key)
    @dynamo_engagement_summary = nil
    Rails.cache.delete(key_for_cache(key))
  end

  def invalidate_legacy_engagement_cache(key)
    Rails.cache.delete(key_for_cache(key, dynamodb_reads: false))
  end
end
