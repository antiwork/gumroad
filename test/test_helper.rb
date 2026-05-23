# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "factory_bot_rails"
require "sidekiq/testing"
require "vcr"
require "webmock/minitest"
require "shoulda-matchers"

$LOAD_PATH.unshift Rails.root.join("test").to_s

Mongoid.load!(Rails.root.join("config", "mongoid.yml"))
Braintree::Configuration.logger = Logger.new(File::NULL)
PayPal::SDK.logger = Logger.new(File::NULL)

FactoryBot.definition_file_paths = [Rails.root.join("test", "factories")]
FactoryBot.find_definitions

Dir[Rails.root.join("test", "support", "*.rb")].sort.each { |file| require file }

RspecCompatInstall.install!(ActiveSupport::TestCase)

module ActiveSupport
  class TestCase
    parallelize(workers: 4)

    # Reuse the existing fixture files we share with the RSpec suite for
    # things like `file_fixture(...)`.
    self.file_fixture_path = Rails.root.join("test", "support", "fixtures")

    # Fixtures live under test/fixtures/. `fixtures :all` is only called once
    # there's at least one fixture file; tests that need fixtures can call
    # `fixtures :name` in their class body.
    fixtures_dir = Rails.root.join("test", "fixtures")
    if fixtures_dir.directory? && Dir[fixtures_dir.join("*.yml")].any?
      fixtures :all
    end

    include FactoryBot::Syntax::Methods
    include ActiveSupport::Testing::TimeHelpers
    include WithConst
    include InertiaTestHelpers
    include ErrorResponses if defined?(ErrorResponses)
    include TaxIdValidationStubs if defined?(TaxIdValidationStubs)
    include StripeMerchantAccountHelper if defined?(StripeMerchantAccountHelper)
    include StripePaymentMethodHelper if defined?(StripePaymentMethodHelper)
    include StripeChargesHelper if defined?(StripeChargesHelper)
    include CardParamsSpecHelper if defined?(CardParamsSpecHelper)
    include EmailHelpers if defined?(EmailHelpers)
    include GeoipMocking if defined?(GeoipMocking)

    setup do
      Sidekiq.redis(&:flushdb)
      $redis.flushdb if defined?($redis)
      %i[
        store_discover_searches
        log_email_events
        follow_wishlists
        seller_refund_policy_new_users_enabled
        paypal_payout_fee
        disable_braintree_sales
      ].each { |feature| Feature.activate(feature) }
      @request.host = DOMAIN if defined?(@request) && @request.respond_to?(:host=)
      PostSendgridApi.mails.clear if defined?(PostSendgridApi)
      stub_webmock if respond_to?(:stub_webmock)
      stub_geoip if respond_to?(:stub_geoip)
      setup_inertia_renderer if rspec_metadata[:inertia]
      stub_tax_id_validation_services if rspec_metadata[:stub_tax_id_validation] && respond_to?(:stub_tax_id_validation_services)
      if rspec_metadata[:without_circle_rate_limit]
        allow_any_instance_of(CircleApi).to receive(:rate_limited_call).and_wrap_original { |method, &block| block.call }
      end
    end

    teardown do
      rspec_expectation_stubs.each(&:verify!)
    ensure
      rspec_stub_restores.reverse_each(&:call)
      WebMock.allow_net_connect!
      Rails.cache.clear
      travel_back
    end
  end
end

class ActionDispatch::IntegrationTest
  parallelize(workers: 4)
  include Devise::Test::IntegrationHelpers
end

class ActionController::TestCase
  include Devise::Test::ControllerHelpers
end

class ActionView::TestCase
  include Devise::Test::ControllerHelpers
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :minitest
    with.library :rails
  end
end

VCR.configure do |config|
  config.cassette_library_dir = Rails.root.join("test", "support", "fixtures", "vcr_cassettes")
  config.hook_into :webmock
  config.ignore_hosts "gumroad-specs.s3.amazonaws.com", "s3.amazonaws.com", "codeclimate.com", "mongo", "redis", "elasticsearch", "minio"
  config.ignore_hosts "googlechromelabs.github.io"
  config.ignore_hosts "storage.googleapis.com"
  config.ignore_localhost = true
  config.debug_logger = $stdout if ENV["VCR_DEBUG"]
  config.default_cassette_options[:record] = ENV["CI"] ? :none : :once
end

WebMock.disable_net_connect!(allow_localhost: true)

def prepare_mysql
  ActiveRecord::Base.connection.execute("SET SESSION information_schema_stats_expiry = 0")
end

def stub_pwned_password_check
  @pwned_password_request_stub = WebMock.stub_request(:get, %r{api\.pwnedpasswords\.com/range/.+})
end

def stub_webmock
  stub_pwned_password_check
end

def with_real_pwned_password_check
  WebMock.remove_request_stub(@pwned_password_request_stub)
  yield
ensure
  stub_webmock
end
