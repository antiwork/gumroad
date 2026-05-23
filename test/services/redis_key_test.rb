# frozen_string_literal: true

require "test_helper"

class RedisKeyTest < ActiveSupport::TestCase
  test ".ai_request_throttle returns a properly formatted redis key with an integer user id" do
    assert_equal "ai_request_throttle:123", RedisKey.ai_request_throttle(123)
  end

  test ".ai_request_throttle handles string user ids" do
    assert_equal "ai_request_throttle:456", RedisKey.ai_request_throttle("456")
  end

  test ".acme_challenge returns a properly formatted redis key with a token" do
    assert_equal "acme_challenge:abc123", RedisKey.acme_challenge("abc123")
  end
end
