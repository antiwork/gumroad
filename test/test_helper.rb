# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
# Mocha adds `.stubs`/`.expects` and, crucially, `any_instance` stubbing — the
# equivalent of RSpec's `allow_any_instance_of`, which `minitest/mock` can't
# express. Required here (not in the RSpec suite) so it never clashes with
# rspec-mocks. Coexists with the block-form `minitest/mock` stubs already in use.
require "mocha/minitest"
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
# Real Elasticsearch echoes every requested aggregation back with a computed
# value; the empty-data equivalent is a zero. Stats code (User#sales_cents_total,
# Product#monthly_recurring_revenue, …) reads `result.aggregations.<name>.value`
# unconditionally, so a response with no "aggregations" key crashes with
# "undefined method 'value' for nil". Build a zeroed skeleton mirroring the
# requested aggs so those reads return 0 the way real ES would on an empty index.
# Only added when aggs are actually requested, so responses that never touched
# aggregations keep their previous shape exactly.
fake_es_zero_aggs = lambda do |aggs|
  aggs.each_with_object({}) do |(name, definition), result|
    definition = definition.is_a?(Hash) ? definition.transform_keys(&:to_s) : {}
    sub = definition["aggs"] || definition["aggregations"]
    node = { "value" => 0, "doc_count" => 0, "buckets" => [] }
    node.merge!(fake_es_zero_aggs.call(sub)) if sub.is_a?(Hash)
    result[name.to_s] = node
  end
end
fake_es.define_singleton_method(:method_missing) do |name, *args, **kwargs|
  case name
  when :count, :search, :msearch
    response = { "count" => 0, "hits" => { "hits" => [], "total" => { "value" => 0 } } }
    # The Elasticsearch Ruby client passes its arguments as a single positional
    # hash (client.search({ index:, body: })), not as keywords, so look in both.
    options = kwargs.any? ? kwargs : (args.first.is_a?(Hash) ? args.first : {})
    body = options[:body] || options["body"]
    requested_aggs = body.is_a?(Hash) ? (body[:aggs] || body["aggs"] || body[:aggregations] || body["aggregations"]) : nil
    response["aggregations"] = fake_es_zero_aggs.call(requested_aggs) if requested_aggs.is_a?(Hash) && requested_aggs.any?
    response
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
      # Flipper is Redis-backed (config/initializers/feature_toggle.rb) and Redis is
      # NOT rolled back with the test transaction, so a feature a test toggles — or any
      # other Redis state (e.g. RedisKey.gumroad_day_date) — would leak into later tests
      # and change behavior (e.g. silently waiving a Gumroad fee). spec_helper flushes
      # both Redis DBs before each example; mirror that here, and BEFORE re-activating the
      # global features below so every test starts from the same known feature set.
      $redis.flushdb
      Sidekiq.redis(&:flushdb)

      %i[
        store_discover_searches
        log_email_events
        seller_refund_policy_new_users_enabled
        paypal_payout_fee
        disable_braintree_sales
      ].each { |feature| Feature.activate(feature) }

      # Creating/saving a User runs Devise's Have I Been Pwned check, which
      # makes a real HTTP request that WebMock blocks. Stub it the way
      # spec_helper's stub_pwned_password_check does.
      WebMock.stub_request(:get, %r{api\.pwnedpasswords\.com/range/.+})
             .to_return(status: 200, body: "", headers: {})

      # Bypass the daily product-creation limit, as spec_helper does (it wraps
      # each example in Link.bypass_product_creation_limit). Tests routinely
      # create many products for one user and shouldn't hit the 10/day cap.
      ActiveSupport::IsolatedExecutionState[:gumroad_bypass_product_creation_limit] = true

      # Sidekiq's fake mode accumulates enqueued jobs in a process-global array.
      # The rspec-sidekiq gem clears it before each example; Minitest has no such
      # hook, so jobs would leak across tests and break absolute job-count
      # assertions (e.g. `assert_equal 0, Worker.jobs.size`). Clear it here.
      Sidekiq::Worker.clear_all

      # The Disk ActiveStorage service (see below) needs url_options to build
      # blob/variant URLs. ActiveStorage::Current is a per-request CurrentAttribute
      # that resets between tests, so set it each time.
      ActiveStorage::Current.url_options = { protocol: "https", host: "localhost", port: nil }
    end
  end
end

# AssetPreviewAnalysisStub injects known metadata for fixture files instead of
# shelling out to the image/video analyzer. It lives under spec/support (shared
# with the RSpec suite) and has no RSpec dependency, so require it directly for
# the asset_preview/thumbnail helpers.
require Rails.root.join("spec", "support", "asset_preview_analysis_stub")

# The RSpec test jobs bring up MinIO (S3) via docker-compose; the lightweight
# Minitest CI job does not. Point ActiveStorage at a local Disk service so
# file-attaching tests (thumbnails, asset previews, public files) never make S3
# network calls — otherwise the upload fails with a connection error that Makara
# escalates to BlacklistedWhileInTransaction. GitHub-hosted runners ship with
# ImageMagick/ffmpeg, so blob analysis and variants still work. A host must be
# set for Disk-service URL generation.
# Re-register the default :test service as a local Disk service (keeping the
# :test name so blob service_name references still resolve), and make it the
# default. Building it through the Registry sets the service name that blob
# validation requires.
ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(
  test: { service: "Disk", root: Rails.root.join("tmp", "minitest_storage").to_s, public: true }
)
ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch(:test)
Rails.application.routes.default_url_options[:host] ||= "localhost"

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
