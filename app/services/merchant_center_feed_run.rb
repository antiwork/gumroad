# frozen_string_literal: true

# One daily run: the legacy feed.xml, then the id-range shards up to
# RedisKey.merchant_center_feed_max_shard. Unset, it writes only feed.xml, as before shards.
# Nothing here registers a shard with Merchant Center.
class MerchantCenterFeedRun
  LEGACY_UNIT = "legacy"
  KILL_SWITCH = :disable_merchant_center_feed
  # Short, so a run that dies frees the feed for its Sidekiq retry.
  LOCK_TTL = 15.minutes.to_i
  # A run abandoned for longer than this starts over instead of resuming.
  PROGRESS_TTL = 12.hours.to_i
  LOCK_SCRIPT_RELEASE = <<~LUA
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    end
    return 0
  LUA
  LOCK_SCRIPT_RENEW = <<~LUA
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("EXPIRE", KEYS[1], ARGV[2])
    end
    return 0
  LUA

  # The worker retries later.
  class GenerationInProgress < StandardError; end
  # Another run may be writing, so this one must stop without publishing.
  class LockLost < StandardError; end
  class KillSwitchEngaged < StandardError; end
  private_constant :KillSwitchEngaged

  def call(max_products: MerchantCenterFeedService::DEFAULT_MAX_PRODUCTS)
    return stopped if kill_switch?

    token = SecureRandom.uuid
    unless $redis.set(RedisKey.merchant_center_feed_lock, token, nx: true, ex: LOCK_TTL)
      raise GenerationInProgress, "another Merchant Center feed run is in progress"
    end

    begin
      run(token, max_products)
    rescue KillSwitchEngaged
      stopped
    ensure
      release_lock(token)
    end
  end

  private
    def run(token, max_products)
      units = [LEGACY_UNIT, *shard_indexes.map { |index| shard_unit(index) }]
      finished = $redis.hkeys(RedisKey.merchant_center_feed_progress)
      finished = [] if (units - finished).empty?
      service = MerchantCenterFeedService.new(on_batch: -> { check_in(token) }, on_upload: -> { renew_lock(token) })

      units.each do |unit|
        next if finished.include?(unit)

        check_in(token)
        publish_unit(service, unit, max_products)
        # Before marking: a run that lost the lock must not write into the next run's progress.
        renew_lock(token)
        mark_finished(unit)
      end

      $redis.del(RedisKey.merchant_center_feed_progress)
      :completed
    end

    def publish_unit(service, unit, max_products)
      items = unit == LEGACY_UNIT ? service.generate(max_products:) : service.generate_shard(shard_index(unit))
      Rails.logger.info("MerchantCenterFeedRun: #{unit} published #{items} items")
    rescue MerchantCenterFeedService::ShardTooLarge => e
      # Retrying cannot help, and it must not hold back the other shards. The previous object
      # stays until someone narrows SHARD_WIDTH.
      ErrorNotifier.notify(e, unit:)
    end

    def shard_indexes
      max_shard = $redis.get(RedisKey.merchant_center_feed_max_shard)&.to_i
      last = MerchantCenterFeedService.last_shard_index
      return [] if max_shard.nil? || last.nil?

      (0..[max_shard, last].min).to_a
    end

    def shard_unit(index) = "shard:#{index}"
    def shard_index(unit) = unit.delete_prefix("shard:").to_i

    def mark_finished(unit)
      $redis.hset(RedisKey.merchant_center_feed_progress, unit, Time.current.to_i)
      $redis.expire(RedisKey.merchant_center_feed_progress, PROGRESS_TTL)
    end

    def kill_switch? = Feature.active?(KILL_SWITCH)

    def stopped
      Rails.logger.warn("MerchantCenterFeedRun: stopped by #{KILL_SWITCH}")
      :stopped
    end

    def check_in(token)
      raise KillSwitchEngaged if kill_switch?

      renew_lock(token)
    end

    def renew_lock(token)
      renewed = $redis.eval(LOCK_SCRIPT_RENEW, keys: [RedisKey.merchant_center_feed_lock], argv: [token, LOCK_TTL])
      raise LockLost, "the Merchant Center feed lock expired mid-run" if renewed.to_i.zero?
    end

    # Runs in an `ensure`: a Redis error here must not replace the run's own result.
    def release_lock(token)
      $redis.eval(LOCK_SCRIPT_RELEASE, keys: [RedisKey.merchant_center_feed_lock], argv: [token])
    rescue Redis::BaseError, RedisClient::Error => e
      Rails.logger.error("MerchantCenterFeedRun: could not release the feed lock (#{e.class}: #{e.message})")
    end
end
