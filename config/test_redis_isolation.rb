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
# Under spring the lease is claimed once per app process, which spring runs per checkout —
# so separate worktrees still get separate blocks, which is the case this exists for. Its
# per-command forks share their server's block, so two simultaneous runs in ONE checkout
# are no more isolated than today; `DISABLE_SPRING=1` gives each its own. A fork cannot
# lease a block of its own, because every store connected at preload against the block the
# server leased — so `register_command!` (wired up in config/spring.rb) makes the overlap
# LOUD instead of silent, which is the whole reason the skip paths above warn. The pid
# guard on the release is what makes the shared lease safe. Note the opt-out below is read
# at preload too, so under a live spring server it needs `DISABLE_SPRING=1` or a
# `bin/spring stop` first.
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
  # `reserved_databases` raises it above whatever .env.test pins.
  RESERVED_DATABASES = 4

  LEASE_KEY_PREFIX = "gumroad:test-redis-slot:"
  LEASE_TTL_SECONDS = 300
  LEASE_REFRESH_SECONDS = 60

  # Field of the lease's companion hash, which tracks the command processes currently
  # sharing the block. Only spring forks land in it.
  COMMANDS_KEY_SUFFIX = ":commands"

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
    # The claim this process holds, or nil. Under spring the forks inherit it, which is
    # what `register_command!` exists to notice.
    attr_reader :claim

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

      reserved = reserved_databases(endpoints)
      claim = claim_slot(server:, databases:, reserved:, warn_io:, key_prefix:)
      return nil if claim.nil?

      claim[:databases].each_with_index do |database, index|
        env[STORE_ENV_VARS.fetch(index)] = "#{server}/#{database}"
      end
      keep_lease_alive(claim)
      release_lease_at_exit(claim)
      @claim = claim

      warn_io.puts("[test-redis-isolation] slot #{claim[:slot]} → Redis databases #{claim[:databases].join(', ')} on #{server}")
      claim[:slot]
    rescue Redis::BaseError, RedisClient::Error, SocketError, Errno::ECONNREFUSED => e
      # Never let leasing stop a test run. Without a reachable Redis the run is about to
      # fail on its own with a clearer error than anything raised from here.
      warn_io.puts("[test-redis-isolation] skipped: #{e.class}: #{e.message}")
      nil
    end

    # The first database a slot may use: above .env.development AND above every index
    # the passed-in env vars name, so a run that falls back to them cannot flush a
    # leased block.
    def reserved_databases(endpoints)
      [RESERVED_DATABASES, endpoints.map { |endpoint| endpoint[:database] }.max + 1].max
    end

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

    # Called from config/spring.rb after spring forks a command process. The fork cannot
    # lease a block of its own — every store connected during preload against the block
    # the server leased, and rewriting ENV here would not move an open connection — so
    # this records the command in the lease's companion hash and warns when a sibling
    # command is already using the same block. Silence is the thing this file cannot
    # afford: a shared block that looks isolated is the original race with a valid lease
    # on top of it.
    def register_command!(warn_io: $stderr, claim: self.claim)
      return nil if claim.nil?

      commands_key = "#{claim.fetch(:key)}#{COMMANDS_KEY_SUFFIX}"
      # Its own connection: the registry socket was opened before the fork, so every
      # command would be writing down one shared file descriptor.
      registry = Redis.new(url: claim.fetch(:registry).id)
      me = Process.pid.to_s

      registry.hset(commands_key, me, Time.now.to_i)
      registry.expire(commands_key, LEASE_TTL_SECONDS)

      siblings = registry.hkeys(commands_key).reject { |pid| pid == me }
      # A command killed with SIGKILL never removes its own field, so a stale pid would
      # warn forever. Spring runs one server per host, so these pids are all local.
      dead, live = siblings.partition { |pid| !process_alive?(pid) }
      registry.hdel(commands_key, *dead) if dead.any?

      owner = Process.pid
      at_exit do
        next unless Process.pid == owner
        registry.hdel(commands_key, me)
      rescue Redis::BaseError, RedisClient::Error, IOError
        # The hash carries the lease's TTL, so a missed cleanup costs a stale warning at
        # worst — never a crash on exit.
      end

      if live.any?
        warn_io.puts(<<~WARNING.chomp)
          [test-redis-isolation] #{live.length + 1} test commands are sharing Redis databases #{claim.fetch(:databases).join(', ')} (pids #{(live + [me]).join(', ')}).
          [test-redis-isolation] Spring preloads the app once per checkout and forks each command from it, so they inherit one lease and will flush each other's keys mid-test. Run them with DISABLE_SPRING=1, or from separate checkouts.
        WARNING
      end

      live
    rescue Redis::BaseError, RedisClient::Error, IOError => e
      # Same rule as install!: never let bookkeeping stop a test run.
      warn_io.puts("[test-redis-isolation] could not register this command: #{e.class}: #{e.message}")
      nil
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

      # Signal 0 asks "may I signal this pid" — EPERM means it exists but belongs to
      # someone else, which still counts as alive.
      def process_alive?(pid)
        Process.kill(0, Integer(pid))
        true
      rescue Errno::ESRCH, ArgumentError, TypeError
        false
      rescue Errno::EPERM
        true
      end
  end
end
