# frozen_string_literal: true

module Post::Caching
  # The _ddb suffix is permanent: dropping it would resurface counts cached
  # before the engagement store moved. dynamodb_reads: false still names the
  # unsuffixed legacy key so event handlers can purge it per installment
  # (Memcached cannot bulk-delete).
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
