# frozen_string_literal: true

class InstallmentIdempotencyService
  TTL_SECONDS = 3600
  IN_FLIGHT_SENTINEL = "in_flight"

  def self.reserve(seller_id:, key:)
    redis_key = build_key(seller_id, key)
    if $redis.set(redis_key, IN_FLIGHT_SENTINEL, ex: TTL_SECONDS, nx: true)
      :reserved
    else
      existing = $redis.get(redis_key)
      return :in_flight if existing == IN_FLIGHT_SENTINEL
      Installment.find_by(id: existing.to_i, seller_id:) || :reserved
    end
  end

  def self.complete(seller_id:, key:, installment_id:)
    $redis.set(build_key(seller_id, key), installment_id.to_s, ex: TTL_SECONDS)
  end

  def self.release(seller_id:, key:)
    $redis.del(build_key(seller_id, key))
  end

  def self.build_key(seller_id, key)
    "idempotency:installment:#{seller_id}:#{key}"
  end
  private_class_method :build_key
end
