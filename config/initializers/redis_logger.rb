# frozen_string_literal: true

if ENV["LOG_REDIS"] == "1"
  $redis.client.logger = Rails.logger
end
