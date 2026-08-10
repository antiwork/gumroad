# frozen_string_literal: true

require "securerandom"
require "socket"

# Gives each concurrent test run its own block of Redis databases.
#
# MySQL and Elasticsearch already isolate per run off TEST_DATABASE_NAME
# (config/database.yml, test/support/real_elasticsearch_bridge.rb). Redis did not:
# .env.test pins fixed indexes and both suites `flushdb` before every test
# (test/test_helper.rb, spec/spec_helper.rb), so two runs on one server wipe each
# other's keys mid-test. The flushes are load-bearing, so isolate the databases.
#
# Leases a block at boot and rewrites the *_REDIS_HOST env vars before anything
# connects. The lease holds a TTL refreshed by a background thread, so a run killed
# with SIGKILL frees its block on its own.
#
# Two invariants the arithmetic must keep:
#   - Leased blocks never include a database any *fallback* run uses. A run that skips
#     leasing keeps the .env.test indexes and flushes them; if a leased block covered
#     one, the skipping run would wipe an isolated run's keys — the original race, now
#     invisible because the victim holds a valid lease. So the floor is derived from
#     the env vars themselves (`reserved_databases`), not hardcoded.
#   - Leased blocks never include 0..3 (.env.development) or the registry index.
#
# Editing .env.test's indexes moves the floor, so two checkouts running concurrently
# across such an edit map the same slot number to different blocks. Change those values
# and the shared-server runs need to be on the same checkout.
#
# Spring preloads the app once per checkout, so a lease claimed at boot belongs to the
# server. `reinstall_after_fork!` (wired up in config/spring.rb) re-leases per command, so
# two concurrent commands from one checkout get separate blocks too. The pid guard on the
# release is what keeps a fork from dropping the lease its server still holds. The opt-out
# below is honoured per command, but a server already booted with it set stays opted out
# until `bin/spring stop`.
#
# Capacity is the constraint: 16 databases is one concurrent run, hence
# `--databases 64` in docker/docker-compose-{local,test-and-ci}.yml. With no free
# block this warns and leaves the env vars alone — the fallback block is disjoint from
# every leased block, so sharing it is the old behavior rather than a new hazard.
module TestRedisIsolation
  # One env var per store, in the order their databases are assigned.
  STORE_ENV_VARS = %w[REDIS_HOST SIDEKIQ_REDIS_HOST RPUSH_REDIS_HOST RACK_ATTACK_REDIS_HOST].freeze

  # Databases 0..3 belong to .env.development. Never hand them to a test run — a test
  # flushing one would wipe the developer's own Redis data. This is only the floor;
  # `reserved_databases` raises it above whatever .env.test pins — which is also what
  # keeps bin/dev-lane's databases (4..9) out of reach, since .env.test pins 10..13.
  RESERVED_DATABASES = 4

  LEASE_KEY_PREFIX = "gumroad:test-redis-slot:"
  LEASE_TTL_SECONDS = 300
  LEASE_REFRESH_SECONDS = 60

  # Release and refresh both compare the token first, so a run can never touch a block
  # that expired out from under it and was re-leased by someone else.
  RELEASE_SCRIPT = <<~LUA
    if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end
    return 0
  LUA

  REFRESH_SCRIPT = <<~LUA
    if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('expire', KEYS[1], ARGV[2]) end
    return 0
  LUA

  class << self
    # Rewrites ENV in place. Returns the claimed slot number, or nil when isolation was
    # skipped (not the test env, opted out, unparseable env, or no free block).
    def install!(env: ENV, warn_io: $stderr, key_prefix: LEASE_KEY_PREFIX)
      return nil unless env["RAILS_ENV"] == "test" || Rails.env.test?
      return nil if truthy?(env["DISABLE_TEST_REDIS_ISOLATION"])

      endpoints = STORE_ENV_VARS.map { |var| parse(env[var]) }
      if endpoints.any?(&:nil?)
        unparseable = STORE_ENV_VARS.reject.with_index { |_, index| endpoints[index] }
        warn_io.puts("[test-redis-isolation] skipped: cannot parse #{unparseable.join(', ')} as host:port/db; falling back to the values as set.")
        return nil
      end

      servers = endpoints.map { |endpoint| endpoint[:server] }.uniq
      if servers.length > 1
        warn_io.puts("[test-redis-isolation] skipped: the four *_REDIS_HOST vars point at #{servers.length} servers (#{servers.join(', ')}); expected one.")
        return nil
      end

      server = servers.first
      databases = database_count(server)
      if databases.nil?
        warn_io.puts("[test-redis-isolation] skipped: #{server} does not answer CONFIG GET databases, so the ceiling is unknown.")
        return nil
      end

      # The floor sits above every database a fallback run would flush, so remember the
      # endpoints as they were before the rewrite — a fork re-leases from these.
      @boot_endpoints ||= endpoints
      reserved = reserved_databases(endpoints)
      claim = claim_slot(server:, databases:, reserved:, warn_io:, key_prefix:)
      return nil if claim.nil?

      claim[:databases].each_with_index do |database, index|
        env[STORE_ENV_VARS.fetch(index)] = "#{server}/#{database}"
      end
      keep_lease_alive(claim)
      release_lease_at_exit(claim)

      warn_io.puts("[test-redis-isolation] slot #{claim[:slot]} → Redis databases #{claim[:databases].join(', ')} on #{server}")
      claim[:slot]
    rescue Redis::BaseError, RedisClient::Error, SocketError, Errno::ECONNREFUSED => e
      # Never let leasing stop a test run. Without a reachable Redis the run is about to
      # fail on its own with a clearer error than anything raised from here.
      warn_io.puts("[test-redis-isolation] skipped: #{e.class}: #{e.message}")
      nil
    end

    # Re-lease per forked command, re-pointing the stores that connected at boot.
    #
    # Leasing reads the ORIGINAL endpoints, not the rewritten ENV: the floor is derived from
    # the values a fallback run would use, and boot has already replaced those with leased
    # ones. Re-deriving from ENV would walk the floor up on every fork.
    def reinstall_after_fork!(env: ENV, warn_io: $stderr, key_prefix: LEASE_KEY_PREFIX)
      return nil if boot_endpoints.nil?

      boot_endpoints.each_with_index { |endpoint, index| env[STORE_ENV_VARS.fetch(index)] = "#{endpoint[:server]}/#{endpoint[:database]}" }
      slot = install!(env:, warn_io:, key_prefix:)

      # Reconnect even when the lease failed. The stores in this fork are still connected to
      # the block the spring server leased at preload, and ENV above now names the fallback
      # ones — so returning early leaves concurrent forks flushing the server's block while
      # the warning says they fell back to .env.test. Fallback is disjoint from every leased
      # block, so moving them there is the pre-branch behavior the warning describes.
      reconnect_stores(env)
      slot
    end

    # Stores that read a *_REDIS_HOST once at boot and cached a connection or URL from it.
    # Anything resolving the env var per call needs nothing here.
    #
    # Constants that capture $redis at class load are the exception this cannot reach —
    # ProductDuplicatorService and PaypalPartnerRestCredentials wrap it in a Redis::Namespace
    # assigned to a constant. They are safe only because test never eager-loads under spring
    # (config/environments/test.rb sets eager_load from CI), so a fork autoloads them after
    # this runs. `CI=1 bin/rspec` under spring would pin them to the server's block.
    # config/initializers/rack_profiler.rb captures the boot $redis the same way; inert
    # because MiniProfiler never authorizes in test.
    def reconnect_stores(env)
      $redis = Redis.new(url: "redis://#{env.fetch('REDIS_HOST')}")

      Sidekiq.configure_client { |config| config.redis = { url: "redis://#{env.fetch('SIDEKIQ_REDIS_HOST')}" } }
      # `config.redis=` only merges options; the internal pool is memoized on first use and
      # would keep serving the databases this process inherited.
      Sidekiq.default_configuration.instance_variable_set(:@redis, nil)

      # Modis has Sidekiq's memoization trap too, neutralized rather than absent: its pool
      # factory reads redis_options at connection-create time, and connection_pool defaults
      # to auto_reload_after_fork. If either changes, clear Modis.connection_pools here.
      Modis.redis_options = { url: "redis://#{env.fetch('RPUSH_REDIS_HOST')}" } if defined?(Modis)

      # Flipper's adapter block reads `$redis` when it builds, but the built DSL is memoized
      # in `Thread.current[:flipper_instance]`, which survives the fork. Dropping it makes the
      # next flag read rebuild the adapter against the client assigned above.
      Flipper.instance = nil if defined?(Flipper)

      return unless defined?(Rack::Attack)
      connection = Redis.new(url: "redis://#{env.fetch('RACK_ATTACK_REDIS_HOST')}")
      Rack::Attack.cache.store = Rack::Attack::StoreProxy::RedisProxy.new(connection)
    end

    # The first database a slot may use: above .env.development AND above every index
    # the passed-in env vars name, so a run that falls back to them cannot flush a
    # leased block.
    def reserved_databases(endpoints)
      [RESERVED_DATABASES, endpoints.map { |endpoint| endpoint[:database] }.max + 1].max
    end

    # The *_REDIS_HOST endpoints as they were before boot rewrote them. nil when boot never
    # leased, in which case a fork has nothing to re-lease from.
    attr_reader :boot_endpoints

    # Pure: which database indexes slot N gets, given a server's database count.
    # nil when the slot does not fit. The last database is the lease registry, so it is
    # excluded from the assignable range.
    def databases_for_slot(slot, databases:, reserved: RESERVED_DATABASES)
      stores = STORE_ENV_VARS.length
      first = reserved + (slot * stores)
      last = first + stores - 1
      return nil if last > registry_database(databases) - 1
      (first..last).to_a
    end

    def slot_count(databases:, reserved: RESERVED_DATABASES)
      assignable = registry_database(databases) - reserved
      return 0 if assignable <= 0
      assignable / STORE_ENV_VARS.length
    end

    def registry_database(databases)
      databases - 1
    end

    def lease_key(slot)
      "#{LEASE_KEY_PREFIX}#{slot}"
    end

    # How many logical databases the server was started with. nil when CONFIG GET is
    # disabled (some managed Redis instances), in which case we cannot know the ceiling
    # and skip isolation rather than guess.
    def database_count(server)
      connection = Redis.new(url: "redis://#{server}/0")
      connection.config(:get, "databases")["databases"]&.to_i
    rescue Redis::CommandError
      nil
    ensure
      connection&.close
    end

    # Claims the first free slot. Returns {slot:, databases:, token:, key:, registry:} or nil.
    # `key_prefix` exists so the spec can lease against this same live Redis without
    # competing for the slot its own run holds.
    def claim_slot(server:, databases:, reserved: RESERVED_DATABASES, warn_io: $stderr, key_prefix: LEASE_KEY_PREFIX)
      slots = slot_count(databases:, reserved:)
      if slots.zero?
        warn_io.puts(capacity_warning(server:, databases:, slots: 0))
        return nil
      end

      registry = Redis.new(url: "redis://#{server}/#{registry_database(databases)}")
      token = "#{Socket.gethostname}:#{Process.pid}:#{SecureRandom.hex(8)}"

      slots.times do |slot|
        key = "#{key_prefix}#{slot}"
        next unless registry.set(key, token, nx: true, ex: LEASE_TTL_SECONDS)
        return { slot:, databases: databases_for_slot(slot, databases:, reserved:), token:, key:, registry: }
      end

      registry.close
      warn_io.puts(capacity_warning(server:, databases:, slots:))
      nil
    end

    def release_lease(claim)
      claim[:registry].eval(RELEASE_SCRIPT, keys: [claim[:key]], argv: [claim[:token]])
    rescue Redis::BaseError, RedisClient::Error, IOError
      # The lease expires on its own; a failure here costs at most LEASE_TTL_SECONDS of
      # one slot and must not turn a passing run into a crash on exit.
    end


    private
      def capacity_warning(server:, databases:, slots:)
        <<~WARNING.chomp
          [test-redis-isolation] no free Redis database block on #{server} (#{databases} databases = #{slots} concurrent run#{'s' unless slots == 1}); falling back to the shared databases in .env.test.
          [test-redis-isolation] Concurrent runs will flush each other's keys mid-test. Start Redis with more databases (docker/docker-compose-local.yml passes --databases 64), or free a slot: a spring server holds its lease until `bin/spring stop`, so idle checkouts keep one.
        WARNING
      end

      # "localhost:6379/10" → { server: "localhost:6379", database: 10 }. Also accepts a
      # bare "host:port" (Redis defaults to database 0). nil when unparseable.
      def parse(value)
        return nil if value.nil? || value.strip.empty?
        match = value.strip.match(%r{\A([^/]+?)(?:/(\d+))?\z})
        return nil if match.nil?
        { server: match[1], database: (match[2] || "0").to_i }
      end

      # Stashes the thread on the claim so the spec can stop it; nothing in boot needs it.
      def keep_lease_alive(claim)
        # Its own connection, so a tick sleeping mid-command cannot delay the exit-time
        # release sharing the same one.
        connection = Redis.new(url: claim.fetch(:registry).id)

        thread = Thread.new do
          loop do
            sleep(LEASE_REFRESH_SECONDS)
            connection.eval(REFRESH_SCRIPT, keys: [claim[:key]], argv: [claim[:token], LEASE_TTL_SECONDS])
          rescue StandardError
            # Every error, not a list: if this thread dies the lease expires mid-run and
            # another run leases the same databases — this file's own race, with nothing
            # to point at. A missed tick is harmless, so retrying forever is the safe shape.
          end
        end
        thread.name = "test-redis-isolation-lease"
        claim[:refresh_thread] = thread
      end

      def release_lease_at_exit(claim)
        # at_exit handlers are inherited across fork, and a child holds the parent's exact
        # token — so without this an exiting child releases the lease the parent is still
        # using, and the token compare cannot tell them apart.
        owner = Process.pid
        at_exit { release_lease(claim) if Process.pid == owner }
      end

      def truthy?(value)
        %w[1 true yes].include?(value.to_s.downcase)
      end
  end
end
