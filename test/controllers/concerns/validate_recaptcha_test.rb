# frozen_string_literal: true

require "test_helper"

class ValidateRecaptchaTestController < ApplicationController
  include ValidateRecaptcha

  def action
    if valid_recaptcha_response?(site_key: "test_site_key")
      render json: { success: true }
    else
      render json: { success: false, error: "captcha_failed" }, status: :unprocessable_entity
    end
  end
end

class ValidateRecaptchaTest < ActionController::TestCase
  include Devise::Test::ControllerHelpers

  tests ValidateRecaptchaTestController

  setup do
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { post "action" => "validate_recaptcha_test#action" }

    @orig_env_test = Rails.env.singleton_class.instance_method(:test?) rescue nil
    Rails.env.singleton_class.send(:define_method, :test?) { false }
    @orig_env_production = Rails.env.singleton_class.instance_method(:production?) rescue nil
    Rails.env.singleton_class.send(:define_method, :production?) { false }
  end

  teardown do
    if @orig_env_test
      Rails.env.singleton_class.send(:define_method, :test?, @orig_env_test)
    else
      Rails.env.singleton_class.send(:remove_method, :test?) if Rails.env.singleton_class.method_defined?(:test?)
    end
    if @orig_env_production
      Rails.env.singleton_class.send(:define_method, :production?, @orig_env_production)
    else
      Rails.env.singleton_class.send(:remove_method, :production?) if Rails.env.singleton_class.method_defined?(:production?)
    end
    WebMock.reset!
  end

  def stub_httparty(parsed_response:, code:, body: nil)
    body ||= parsed_response.is_a?(String) ? parsed_response : parsed_response.to_json
    stubbed = Object.new
    stubbed.define_singleton_method(:parsed_response) { parsed_response }
    stubbed.define_singleton_method(:code) { code }
    stubbed.define_singleton_method(:to_s) { body }
    HTTParty.singleton_class.send(:alias_method, :__orig_post, :post) unless HTTParty.singleton_class.method_defined?(:__orig_post)
    HTTParty.define_singleton_method(:post) { |*_a, **_kw| stubbed }
  end

  def unstub_httparty
    if HTTParty.singleton_class.method_defined?(:__orig_post)
      HTTParty.singleton_class.send(:remove_method, :post)
      HTTParty.singleton_class.send(:alias_method, :post, :__orig_post)
      HTTParty.singleton_class.send(:remove_method, :__orig_post)
    end
  end

  test "returns parsed hash when API returns valid JSON" do
    stub_httparty(parsed_response: { "tokenProperties" => { "valid" => true } }, code: 200)
    begin
      post :action, params: { "g-recaptcha-response" => "test_token" }
      assert_response :ok
      assert_equal true, JSON.parse(@response.body)["success"]
    ensure
      unstub_httparty
    end
  end

  test "returns empty hash when API returns non-JSON response (HTML error page)" do
    stub_httparty(parsed_response: "<html>Error</html>", code: 502, body: "<html>Error</html>")
    begin
      post :action, params: { "g-recaptcha-response" => "test_token" }
      assert_response :unprocessable_entity
      assert_equal "captcha_failed", JSON.parse(@response.body)["error"]
    ensure
      unstub_httparty
    end
  end

  test "returns empty hash when API returns nil parsed response" do
    stub_httparty(parsed_response: nil, code: 200, body: "")
    begin
      post :action, params: { "g-recaptcha-response" => "test_token" }
      assert_response :unprocessable_entity
    ensure
      unstub_httparty
    end
  end

  test "returns empty hash when HTTParty raises an error" do
    HTTParty.singleton_class.send(:alias_method, :__orig_post, :post) unless HTTParty.singleton_class.method_defined?(:__orig_post)
    HTTParty.define_singleton_method(:post) { |*_a, **_kw| raise Net::OpenTimeout.new("execution expired") }
    begin
      post :action, params: { "g-recaptcha-response" => "test_token" }
      assert_response :unprocessable_entity
      assert_equal "captcha_failed", JSON.parse(@response.body)["error"]
    ensure
      unstub_httparty
    end
  end
end
