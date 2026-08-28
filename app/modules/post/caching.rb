# frozen_string_literal: true

module Post::Caching
  # The _ddb namespace keeps legacy cached counters from surviving the read
  # flip (Memcached cannot bulk-delete): flipping email_engagement_dynamodb_reads
  # moves every fetch and every invalidation to fresh keys together.
  def key_for_cache(key, dynamodb_reads: EmailEngagementDynamoStore.reads_enabled?)
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
