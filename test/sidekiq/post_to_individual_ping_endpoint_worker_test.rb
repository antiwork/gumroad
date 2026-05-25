# frozen_string_literal: true

require "test_helper"

class PostToIndividualPingEndpointWorkerTest < ActiveSupport::TestCase
  def setup
    @http_double = Object.new
    def @http_double.success?; true; end
    def @http_double.code; 200; end
  end

  # Capture HTTParty.post as an UnboundMethod so we can restore it faithfully
  # in teardown. `remove_method(:post)` would strip the real implementation
  # (it's defined directly on HTTParty's singleton class), leaking
  # `NoMethodError: undefined method 'post' for HTTParty` into sibling tests.
  def stub_httparty_post(expected_args_matcher)
    calls = []
    orig_post = HTTParty.singleton_class.instance_method(:post)
    HTTParty.define_singleton_method(:post) do |*args, **kwargs|
      calls << [args, kwargs]
      expected_args_matcher.call(args, kwargs) if expected_args_matcher
      @stub_response
    end
    HTTParty.instance_variable_set(:@stub_response, @http_double)
    yield calls
  ensure
    HTTParty.singleton_class.send(:define_method, :post, orig_post) if orig_post
    HTTParty.instance_variable_set(:@stub_response, nil)
  end

  test "posts url-encoded form data" do
    stub_httparty_post(nil) do |calls|
      assert_nothing_raised do
        PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "a" => 1 }, Mime[:url_encoded_form].to_s)
      end
      assert_equal 1, calls.size
      url, args = calls.first[0][0], calls.first[1]
      assert_equal "http://notification.com", url
      assert_equal 5, args[:timeout]
      assert_equal({ "a" => 1 }, args[:body])
      assert_equal "application/x-www-form-urlencoded", args[:headers]["Content-Type"]
    end
  end

  test "url-encoded body encodes brackets in keys" do
    stub_httparty_post(nil) do |calls|
      PostToIndividualPingEndpointWorker.new.perform(
        "http://notification.com",
        { "name [for field] [[]]!@#$%^&" => 1, custom_fields: { "name [for field] [[]]!@#$%^&" => 1 } },
        Mime[:url_encoded_form].to_s
      )
      body = calls.first[1][:body]
      assert body.key?("name %5Bfor field%5D %5B%5B%5D%5D!@\#$%^&")
      assert body["custom_fields"].key?("name %5Bfor field%5D %5B%5B%5D%5D!@\#$%^&")
    end
  end

  test "posts JSON body" do
    stub_httparty_post(nil) do |calls|
      PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "some [thing]" => 1 }, Mime[:json].to_s)
      args = calls.first[1]
      assert_equal({ "some [thing]" => 1 }.to_json, args[:body])
      assert_equal "application/json", args[:headers]["Content-Type"]
    end
  end

  test "does not raise on SocketError" do
    orig_post = HTTParty.singleton_class.instance_method(:post)
    orig_info = Rails.logger.singleton_class.instance_method(:info) rescue nil
    HTTParty.define_singleton_method(:post) { |*_a, **_k| raise SocketError.new("socket error message") }
    log_msgs = []
    Rails.logger.define_singleton_method(:info) { |msg| log_msgs << msg }
    begin
      PostToIndividualPingEndpointWorker.new.perform("http://example.com", { "q" => 47 })
    ensure
      if orig_info
        Rails.logger.singleton_class.send(:define_method, :info, orig_info)
      else
        Rails.logger.singleton_class.send(:remove_method, :info) if Rails.logger.singleton_class.method_defined?(:info)
      end
      HTTParty.singleton_class.send(:define_method, :post, orig_post)
    end
    assert log_msgs.any? { |m| m.include?("[SocketError]") && m.include?("PostToIndividualPingEndpointWorker") && m.include?("socket error message") }
  end

  test "re-raises non-internet error" do
    orig_post = HTTParty.singleton_class.instance_method(:post)
    HTTParty.define_singleton_method(:post) { |*_a, **_k| raise StandardError }
    begin
      assert_raises(StandardError) do
        PostToIndividualPingEndpointWorker.new.perform("http://notification.com", { "q" => 47 })
      end
    ensure
      HTTParty.singleton_class.send(:define_method, :post, orig_post)
    end
  end

  test "logs response code, url and params" do
    stub_httparty_post(nil) do |_calls|
      log_msgs = []
      orig_info = Rails.logger.singleton_class.instance_method(:info) rescue nil
      Rails.logger.define_singleton_method(:info) { |msg| log_msgs << msg }
      begin
        PostToIndividualPingEndpointWorker.new.perform("https://notification.com", { "a" => 1 })
      ensure
        if orig_info
          Rails.logger.singleton_class.send(:define_method, :info, orig_info)
        else
          Rails.logger.singleton_class.send(:remove_method, :info) if Rails.logger.singleton_class.method_defined?(:info)
        end
      end
      assert log_msgs.any? { |m| m.include?("response=200") && m.include?("url=https://notification.com") && m.include?("\"a\"") && m.include?("=>") }
    end
  end
end
