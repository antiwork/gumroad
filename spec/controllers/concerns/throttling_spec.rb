# frozen_string_literal: true

require "spec_helper"

describe Throttling do
  let(:dummy_class) do
    Class.new do
      include Throttling
      attr_accessor :response, :rendered_options, :headers

      def initialize
        @response = OpenStruct.new
        @rendered_options = nil
        @headers = {}
      end

      def render(options)
        @rendered_options = options
      end
    end
  end

  let(:controller) { dummy_class.new }
  let(:redis) { Redis.new }

  before do
    allow(controller.response).to receive(:set_header) do |header, value|
      controller.headers[header] = value
    end
    redis.flushdb
  end

  describe "#throttle!" do
    it "allows requests within the limit" do
      result = controller.send(:throttle!, key: "test_key", limit: 5, period: 3600, redis: redis)

      expect(result).to be true
      expect(controller.rendered_options).to be_nil
    end

    it "blocks requests when limit is exceeded" do
      # Make 5 requests (the limit)
      5.times do
        result = controller.send(:throttle!, key: "test_key", limit: 5, period: 3600, redis: redis)
        expect(result).to be true
      end

      # The 6th request should be blocked
      result = controller.send(:throttle!, key: "test_key", limit: 5, period: 3600, redis: redis)

      expect(result).to be false
      expect(controller.rendered_options[:json][:error]).to match(/Rate limit exceeded/)
      expect(controller.rendered_options[:status]).to eq(:too_many_requests)
      expect(controller.response).to have_received(:set_header).with("Retry-After", anything)
    end

    it "sets expiration on first request" do
      controller.send(:throttle!, key: "test_key", limit: 5, period: 3600, redis: redis)

      ttl = redis.ttl("test_key")
      expect(ttl).to be > 0
      expect(ttl).to be <= 3600
    end

    it "does not reset expiration on subsequent requests" do
      controller.send(:throttle!, key: "test_key", limit: 5, period: 3600, redis: redis)
      initial_ttl = redis.ttl("test_key")

      sleep(1)

      # Second request should not reset expiration
      controller.send(:throttle!, key: "test_key", limit: 5, period: 3600, redis: redis)
      second_ttl = redis.ttl("test_key")

      expect(second_ttl).to be < initial_ttl
    end
  end
end
