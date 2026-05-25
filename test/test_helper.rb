# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "webmock/minitest"
require "sidekiq/testing"
Sidekiq::Testing.fake!

# Disable network access in tests (matches RSpec's webmock config).
WebMock.disable_net_connect!(allow_localhost: true)

# Stub Elasticsearch globally so any model save/callback that calls EsClient
# (search reindex, ProductPageView.count, etc.) doesn't make a real HTTP
# request to localhost:9200, where 6 Faraday retries × N parallel test workers
# saturates Makara's connection pool (each retry holds the AR thread inside an
# Executor wrapper) and crashes the whole suite with AllConnectionsBlacklisted.
require "elasticsearch"
fake_es = Object.new
fake_es.define_singleton_method(:method_missing) do |name, *_args, **_kwargs|
  case name
  when :count, :search, :msearch then { "count" => 0, "hits" => { "hits" => [], "total" => { "value" => 0 } } }
  when :indices then self
  when :exists?, :exists then false
  when :index, :update, :delete, :delete_by_query, :create, :put, :put_alias, :put_mapping, :put_settings, :scroll, :clear_scroll, :update_by_query then { "result" => "noop", "_shards" => { "successful" => 0 }, "hits" => { "hits" => [] } }
  when :transport then self
  when :logger, :logger= then nil
  else nil
  end
end
fake_es.define_singleton_method(:respond_to_missing?) { |_n, _p = false| true }
if defined?(EsClient)
  Object.send(:remove_const, :EsClient)
end
Object.const_set(:EsClient, fake_es)
# Elasticsearch::Model.client is the lookup used by classes that `include
# Elasticsearch::Model` (Purchase, ConfirmedFollowerEvent, ProductPageView,
# etc.). Set it to the fake too.
Elasticsearch::Model.client = fake_es if defined?(Elasticsearch::Model)

# Stub WithMaxExecutionTime in tests — it issues SET SESSION max_execution_time
# on the AR connection, which fails under Makara when the replica is briefly
# unavailable. The failure isn't recoverable (the `ensure` block runs the
# unset against a now-blacklisted connection, triggering a recursive blacklist
# cascade that takes down the entire suite). Tests don't need real query
# timeouts; just yield the block.
require Rails.root.join("lib", "utilities", "with_max_execution_time") if File.exist?(Rails.root.join("lib", "utilities", "with_max_execution_time.rb"))
if defined?(WithMaxExecutionTime)
  module WithMaxExecutionTime
    def self.timeout_queries(seconds:)
      yield
    end
  end
end

# Disable Makara connection blacklisting in tests. CI sometimes hits transient
# connection issues (especially during shutdown) that blacklist primary, which
# then crashes teardown's disable_query_cache! callback with
# Makara::Errors::AllConnectionsBlacklisted. We never test failover; treat
# every connection as fresh.
if defined?(Makara::Pool)
  Makara::Pool.class_eval do
    def connection_made?
      true
    end
  end
  Makara::ConnectionWrapper.class_eval do
    def _makara_blacklist!
      # no-op in test env
    end
    def _makara_blacklisted?
      false
    end
  end if defined?(Makara::ConnectionWrapper)
end

module ActiveSupport
  class TestCase
    # Reuse the existing fixture files we share with the RSpec suite for
    # things like `file_fixture(...)`.
    self.file_fixture_path = Rails.root.join("spec", "support", "fixtures")

    # Fixtures live under test/fixtures/. `fixtures :all` is only called
    # once there's at least one fixture file; tests that need fixtures
    # can call `fixtures :name` in their class body. We're on the
    # fixtures-only migration path (no FactoryBot).
    fixtures_dir = Rails.root.join("test", "fixtures")
    if fixtures_dir.directory? && Dir[fixtures_dir.join("*.yml")].any?
      fixtures :all
    end

    # Activate features that the RSpec suite activates globally in
    # spec_helper.rb (`config.before(:each)` around line 336). Tests that
    # un-stubbed from RSpec inherit this assumption — e.g. EmailEvent
    # writes are gated on `:log_email_events`, otherwise the observer
    # silently no-ops and `assert_difference { EmailEvent.count }` fails.
    setup do
      %i[
        store_discover_searches
        log_email_events
        follow_wishlists
        seller_refund_policy_new_users_enabled
        paypal_payout_fee
        disable_braintree_sales
      ].each { |feature| Feature.activate(feature) }
    end
  end
end

# Load shared test-support modules.
Dir[Rails.root.join("test", "support", "**", "*.rb")].sort.each { |f| require f }

# Stub Vite manifest lookups so mailer/view tests don't depend on a built
# Vite manifest. CI skips the JS build for speed (Minitest is Ruby-only),
# so we monkey-patch ViteRuby::Manifest to return empty/synthetic responses
# instead of raising "Vite Ruby can't find entrypoints/X in the manifests."
require "vite_ruby"
module ViteManifestTestStub
  def resolve_entries(*_names, **_kwargs)
    { scripts: [], stylesheets: [], imports: [] }
  end

  def lookup!(name, **_kwargs)
    { "file" => "/vite-test/#{name}", "src" => name }
  end

  def lookup(name, **_kwargs)
    { "file" => "/vite-test/#{name}", "src" => name }
  end

  def path_for(name, **_kwargs)
    "/vite-test/#{name}"
  end
end
ViteRuby::Manifest.prepend(ViteManifestTestStub)
