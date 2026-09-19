# frozen_string_literal: true

$redis = Redis.new(url: "redis://#{ENV["REDIS_HOST"]}")

# What a stalled read or write raises. redis-client reports its own timeouts and connection
# failures as RedisClient::Error, which is not a Redis::BaseError, so a rescue naming only the
# latter misses the failure it was written for.
REDIS_TRANSPORT_ERRORS = [Redis::BaseError, RedisClient::Error].freeze
