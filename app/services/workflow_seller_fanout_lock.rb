# frozen_string_literal: true

# One large workflow publish at a time per seller. Publishing several six-figure
# posts together used to enqueue every recipient immediately and stall checkout.
class WorkflowSellerFanoutLock
  DEFAULT_TTL = 20.minutes
  DEFAULT_RETRY = 30.seconds

  RELEASE_IF_HELD = <<~LUA
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    end
    return 0
  LUA

  RENEW_IF_HELD = <<~LUA
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("EXPIRE", KEYS[1], ARGV[2])
    end
    return 0
  LUA

  def self.acquire(seller_id)
    return new(seller_id: seller_id, token: nil, fail_open: true) if seller_id.blank?

    token = SecureRandom.uuid
    key = RedisKey.workflow_seller_fanout_lock(seller_id)
    acquired = $redis.set(key, token, nx: true, ex: ttl_seconds)
    return unless acquired

    new(seller_id:, token:)
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, seller_id:)
    new(seller_id:, token: nil, fail_open: true)
  end

  def self.retry_in
    ($redis.get(RedisKey.workflow_seller_fanout_retry_seconds) || DEFAULT_RETRY).to_i.seconds
  rescue Redis::BaseError, RedisClient::Error
    DEFAULT_RETRY
  end

  def self.ttl_seconds
    ($redis.get(RedisKey.workflow_seller_fanout_lock_ttl_seconds) || DEFAULT_TTL).to_i
  rescue Redis::BaseError, RedisClient::Error
    DEFAULT_TTL.to_i
  end

  def initialize(seller_id:, token:, fail_open: false)
    @seller_id = seller_id
    @token = token
    @fail_open = fail_open
  end

  def renew
    return true if @fail_open || @token.blank?

    $redis.eval(RENEW_IF_HELD, keys: [key], argv: [@token, self.class.ttl_seconds]).to_i == 1
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, seller_id: @seller_id)
    true
  end

  def release
    return if @fail_open || @token.blank?

    $redis.eval(RELEASE_IF_HELD, keys: [key], argv: [@token])
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, seller_id: @seller_id)
  end

  private
    def key
      RedisKey.workflow_seller_fanout_lock(@seller_id)
    end
end
