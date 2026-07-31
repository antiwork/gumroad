# frozen_string_literal: true

require "securerandom"
require "socket"

# Gives each concurrent test run its own block of Redis databases.
#
# MySQL and Elasticsearch are already isolated per run — the database name comes from
# TEST_DATABASE_NAME (config/database.yml) and ES index names are namespaced with it
# (test/support/real_elasticsearch_bridge.rb). Redis was not: .env.test pins fixed
# database indexes, and both suites call `flushdb` before every test
# (test/test_helper.rb, spec/spec_helper.rb). Each flush is correct alone and is
# load-bearing for per-test isolation, but two runs on one Redis server flush each
# other's keys mid-test. A test whose subject reads Redis then asserts against a key
# a sibling process erased, and it fails looking like a logic bug.
#
# So: lease a private block of database indexes at boot and rewrite the *_REDIS_HOST
# env vars before anything connects. The lease lives in the highest database index on
# the same server, holds a TTL, and is refreshed by a background thread, so a run
# killed with SIGKILL frees its block on its own.
#
# Capacity is the constraint — Redis ships with 16 databases, and four of those are
# the developer's own .env.development block. Raise it (`redis-server --databases 64`,
# already set in docker/docker-compose-local.yml and
# docker/docker-compose-test-and-ci.yml) to get more concurrent runs. When every block
# is leased this warns and leaves the env vars alone rather than raising: falling back
# to today's shared behavior keeps a run working, and the warning says what to do.
module TestRedisIsolation
  # One env var per store, in the order their databases are assigned.
  STORE_ENV_VARS = %w[REDIS_HOST SIDEKIQ_REDIS_HOST RPUSH_REDIS_HOST RACK_ATTACK_REDIS_HOST].freeze

  # Databases 0..3 belong to .env.development. Never hand them to a test run — a test
  # flushing one would wipe the developer's own Redis data.
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
    def install!(env: ENV, warn_io: $stderr)
      return nil unless env["RAILS_ENV"] == "test" || Rails.env.test?
      return nil if truthy?(env["DISABLE_TEST_REDIS_ISOLATION"])

      endpoints = STORE_ENV_VARS.map { |var| parse(env[var]) }
      return nil if endpoints.any?(&:nil?)

      servers = endpoints.map { |endpoint| endpoint[:server] }.uniq
      if servers.length > 1
        warn_io.puts("[test-redis-isolation] skipped: the four *_REDIS_HOST vars point at #{servers.length} servers (#{servers.join(', ')}); expected one.")
        return nil
      end

      server = servers.first
      databases = database_count(server)
      return nil if databases.nil?

      claim = claim_slot(server:, databases:, warn_io:)
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

    # Pure: which database indexes slot N gets, given a server's database count.
    # nil when the slot does not fit. The last database is the lease registry, so it is
    # excluded from the assignable range.
    def databases_for_slot(slot, databases:, stores: STORE_ENV_VARS.length, reserved: RESERVED_DATABASES)
      first = reserved + (slot * stores)
      last = first + stores - 1
      return nil if last > registry_database(databases) - 1
      (first..last).to_a
    end

    def slot_count(databases:, stores: STORE_ENV_VARS.length, reserved: RESERVED_DATABASES)
      assignable = registry_database(databases) - reserved
      return 0 if assignable <= 0
      assignable / stores
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
    def claim_slot(server:, databases:, warn_io: $stderr, key_prefix: LEASE_KEY_PREFIX)
      slots = slot_count(databases:)
      if slots.zero?
        warn_io.puts(capacity_warning(server:, databases:, slots: 0))
        return nil
      end

      registry = Redis.new(url: "redis://#{server}/#{registry_database(databases)}")
      token = "#{Socket.gethostname}:#{Process.pid}:#{SecureRandom.hex(8)}"

      slots.times do |slot|
        key = "#{key_prefix}#{slot}"
        next unless registry.set(key, token, nx: true, ex: LEASE_TTL_SECONDS)
        return { slot:, databases: databases_for_slot(slot, databases:), token:, key:, registry: }
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
          [test-redis-isolation] Concurrent runs will flush each other's keys mid-test. Start Redis with more databases (docker/docker-compose-local.yml passes --databases 64) or wait for a run to finish.
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

      def keep_lease_alive(claim)
        Thread.new do
          loop do
            sleep(LEASE_REFRESH_SECONDS)
            claim[:registry].eval(REFRESH_SCRIPT, keys: [claim[:key]], argv: [claim[:token], LEASE_TTL_SECONDS])
          rescue Redis::BaseError, RedisClient::Error, IOError
            # Transient: the next tick retries, and the lease outlives one missed refresh.
          end
        end.tap { |thread| thread.name = "test-redis-isolation-lease" }
      end

      def release_lease_at_exit(claim)
        at_exit { release_lease(claim) }
      end

      def truthy?(value)
        %w[1 true yes].include?(value.to_s.downcase)
      end
  end
end
