# frozen_string_literal: true

$redis = Redis.new(url: "redis://#{ENV["REDIS_HOST"]}")
