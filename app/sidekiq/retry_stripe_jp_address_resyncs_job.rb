# frozen_string_literal: true

class RetryStripeJpAddressResyncsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 1.hour

  FIELD_PREFIXES = %w[individual.address_kanji. individual.address_kana.].freeze
  MAX_ATTEMPTS = 8
  RETRY_INTERVAL_DAYS = 7
  BATCH_SIZE = 1_000

  def perform
    candidates.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      ReplicaLagWatcher.watch
      batch.filter_map { |request| request.user_id if due?(request) }
           .uniq
           .each { |user_id| RetryStripeJpAddressResyncForSellerJob.perform_async(user_id) }
    end
  end

  def self.attempts(request)
    request.json_data["address_resync_count"].to_i
  end

  def self.requests_for(user)
    user.user_compliance_info_requests.requested
        .where(FIELD_PREFIXES.map { "field_needed LIKE ?" }.join(" OR "), *FIELD_PREFIXES.map { |prefix| "#{prefix}%" })
        .select { |request| due_for_retry?(request) }
  end

  def self.due_for_retry?(request)
    return false if attempts(request) >= MAX_ATTEMPTS

    last = request.json_data["address_resync_at"]
    last.blank? || Time.iso8601(last) + RETRY_INTERVAL_DAYS.days <= Time.current
  rescue ArgumentError
    true
  end

  private
    def candidates
      UserComplianceInfoRequest.requested
        .where(FIELD_PREFIXES.map { "field_needed LIKE ?" }.join(" OR "), *FIELD_PREFIXES.map { |prefix| "#{prefix}%" })
    end

    def due?(request)
      self.class.due_for_retry?(request)
    end
end
