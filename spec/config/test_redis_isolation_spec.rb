# frozen_string_literal: true

require "spec_helper"

# Guards the per-run Redis database isolation added for the race in
# gumroad-private#1641: two test processes sharing one Redis database, each calling
# `flushdb` before every test, erase each other's keys mid-test.
#
# The lease examples run against the LIVE Redis this suite is already connected to,
# because the bug is a real concurrency bug and a mocked registry would prove nothing
# about it. Every claim goes through a private key prefix and is released in an
# `ensure`, so no example can take the slot this run itself holds or leak into a
# sibling run.
describe TestRedisIsolation do
  # The four *_REDIS_HOST env vars, in assignment order.
  let(:stores) { described_class::STORE_ENV_VARS.length }
  let(:server) { parse(ENV.fetch("REDIS_HOST")).fetch(:server) }
  # Read from the live server rather than assumed: the lease examples write to the
  # registry database, so an index past this server's ceiling would just error.
  let(:databases) { described_class.database_count(server) }
  let(:test_prefix) { "gumroad:test-redis-slot-spec:#{SecureRandom.hex(6)}:" }

  def parse(value)
    described_class.send(:parse, value)
  end

  def claim(count: databases, reserved: described_class::RESERVED_DATABASES, warn_io: StringIO.new)
    described_class.claim_slot(server:, databases: count, reserved:, warn_io:, key_prefix: test_prefix)
  end

  def with_registry(count = databases)
    registry = Redis.new(url: "redis://#{server}/#{described_class.registry_database(count)}")
    yield registry
  ensure
    registry&.close
  end

  def all_blocks(count = databases, reserved: described_class::RESERVED_DATABASES)
    Array.new(described_class.slot_count(databases: count, reserved:)) do |slot|
      described_class.databases_for_slot(slot, databases: count, reserved:)
    end
  end

  # Drops the lease AND the refresh thread install! started, so an example cannot leave
  # a thread ticking a deleted key for the rest of the suite.
  def discard(claimed)
    return if claimed.nil?
    claimed[:refresh_thread]&.kill
    with_registry { |registry| registry.del(claimed[:key]) }
  end

  # The .env.test-shaped endpoints a run starts from, before any rewrite.
  def base_env
    {
      "RAILS_ENV" => "test",
      "REDIS_HOST" => "#{server}/10",
      "SIDEKIQ_REDIS_HOST" => "#{server}/11",
      "RPUSH_REDIS_HOST" => "#{server}/12",
      "RACK_ATTACK_REDIS_HOST" => "#{server}/13",
    }
  end

  # A stock `redis-server` ships 16 databases, which leaves no block above the .env.test
  # indexes — so the examples that need a real lease would fail there for a reason that
  # is not a regression. Skip loudly instead.
  def skip_without_a_free_block
    reserved = described_class.reserved_databases(base_env.values_at(*described_class::STORE_ENV_VARS).map { parse(it) })
    return if described_class.slot_count(databases:, reserved:).positive?
    skip("needs a Redis started with --databases 64; #{databases} leaves no block above #{reserved - 1}")
  end

  describe ".databases_for_slot" do
    it "gives each slot its own block of four databases with no overlap" do
      blocks = all_blocks(64)

      expect(blocks.length).to be > 1
      expect(blocks.map(&:length).uniq).to eq([stores])
      expect(blocks.flatten.uniq.length).to eq(blocks.length * stores)
    end

    it "never hands out a database reserved for .env.development" do
      # 0..3 are the developer's own block. A test flushing one would wipe their local
      # Redis data, which is the failure mode this reservation exists to prevent.
      assigned = all_blocks(64).flatten

      expect(assigned.min).to eq(described_class::RESERVED_DATABASES)
      expect(assigned & (0...described_class::RESERVED_DATABASES).to_a).to be_empty
    end

    it "never hands out the lease registry database" do
      registry = described_class.registry_database(64)

      expect(all_blocks(64).flatten).not_to include(registry)
      expect(all_blocks(64).flatten.max).to be < registry
    end

    it "returns nil for a slot that would run past the registry database" do
      slots = described_class.slot_count(databases: 64)

      expect(described_class.databases_for_slot(slots - 1, databases: 64)).to be_present
      expect(described_class.databases_for_slot(slots, databases: 64)).to be_nil
    end

    it "fits only two runs on a stock 16-database server at the bare floor" do
      # The number that makes the compose `--databases 64` change load-bearing. The real
      # floor is higher than 4 once .env.test's own indexes are excluded, which is why a
      # stock 16-database server ends up with no slots at all.
      expect(described_class.slot_count(databases: 16)).to eq(2)
      expect(described_class.slot_count(databases: 64)).to eq(14)
    end
  end

  describe ".reserved_databases" do
    # The invariant that keeps the fallback safe. A run that skips leasing keeps the
    # .env.test indexes and flushes them, so no leased block may contain one — otherwise
    # the skipping run wipes an isolated run's keys while that run holds a valid lease.
    let(:fallback) { [10, 11, 12, 13] }
    let(:endpoints) { fallback.map { { server:, database: it } } }

    it "puts the floor above every database the env vars name" do
      expect(described_class.reserved_databases(endpoints)).to eq(fallback.max + 1)
    end

    it "never drops below the .env.development reservation for low fallback indexes" do
      # The CI images pin 0..3, where the .env.development reservation is the binding one.
      low = [0, 1, 2, 3].map { { server:, database: it } }

      expect(described_class.reserved_databases(low)).to eq(described_class::RESERVED_DATABASES)
    end

    it "keeps every leased block disjoint from the fallback databases" do
      reserved = described_class.reserved_databases(endpoints)
      assigned = all_blocks(64, reserved:).flatten

      expect(assigned).to be_present
      expect(assigned & fallback).to be_empty
      expect(assigned & (0...described_class::RESERVED_DATABASES).to_a).to be_empty
      expect(assigned).not_to include(described_class.registry_database(64))
    end

    it "leaves no assignable block on a stock 16-database server rather than reusing one" do
      reserved = described_class.reserved_databases(endpoints)

      expect(described_class.slot_count(databases: 16, reserved:)).to eq(0)
    end
  end

  describe ".claim_slot" do
    it "gives two concurrent claims non-overlapping database blocks" do
      first = second = nil

      begin
        first = claim
        second = claim

        expect(first).to be_present
        expect(second).to be_present
        expect(second[:slot]).not_to eq(first[:slot])
        expect(first[:databases] & second[:databases]).to be_empty
      ensure
        [first, second].compact.each { described_class.release_lease(it) }
      end
    end

    it "holds the lease under its own token with a TTL so a killed run frees its slot" do
      claimed = claim

      begin
        with_registry do |registry|
          expect(registry.get(claimed[:key])).to eq(claimed[:token])
          # A SIGKILLed run never reaches its at_exit, so expiry is the only thing that
          # returns the slot. -1 (no TTL) would strand it forever.
          expect(registry.ttl(claimed[:key])).to be_between(1, described_class::LEASE_TTL_SECONDS)
        end
      ensure
        described_class.release_lease(claimed)
      end
    end

    it "frees the slot on release so the next run claims it" do
      first = claim
      slot = first[:slot]
      described_class.release_lease(first)

      second = claim
      begin
        expect(second[:slot]).to eq(slot)
      ensure
        described_class.release_lease(second)
      end
    end

    it "does not release a slot another run has since taken over" do
      claimed = claim

      begin
        with_registry do |registry|
          # Stands in for: this run's lease expired and another run claimed the slot.
          registry.set(claimed[:key], "another-run", ex: described_class::LEASE_TTL_SECONDS)

          described_class.release_lease(claimed)

          expect(registry.get(claimed[:key])).to eq("another-run")
        end
      ensure
        with_registry { |registry| registry.del(claimed[:key]) }
      end
    end

    it "warns and returns nil when every slot is taken rather than sharing a block" do
      taken = []
      warnings = StringIO.new

      begin
        # Two slots is a stock 16-database Redis at the bare floor; a third run must be
        # told it is falling back rather than handed a block someone else is flushing.
        2.times { taken << claim(count: 16) }
        expect(taken.compact.length).to eq(2)

        expect(claim(count: 16, warn_io: warnings)).to be_nil
        expect(warnings.string).to include("no free Redis database block")
        expect(warnings.string).to include("--databases 64")
      ensure
        taken.compact.each { described_class.release_lease(it) }
      end
    end
  end

  describe ".install!" do
    # install! claims a real lease, so these examples route it through the spec's own
    # prefix and capture the claim in order to release it and stop its refresh thread.
    attr_reader :claimed

    def install(env, warn_io: StringIO.new)
      allow(described_class).to receive(:claim_slot).and_wrap_original do |original, **kwargs|
        @claimed = original.call(**kwargs)
      end
      described_class.install!(env:, warn_io:, key_prefix: test_prefix)
    end

    after { discard(claimed) }

    it "rewrites all four store env vars to the one block it leased" do
      skip_without_a_free_block
      env = base_env.dup

      expect(install(env)).to be_present

      rewritten = described_class::STORE_ENV_VARS.map { parse(env.fetch(it)) }
      expect(rewritten.map { it.fetch(:database) }).to eq(claimed.fetch(:databases))
      expect(rewritten.map { it.fetch(:server) }.uniq).to eq([server])
    end

    it "leases a block that a run falling back to .env.test would not flush" do
      # The regression for the overlap the arithmetic originally had: slots were dealt
      # from database 4 up, so slot 1 covered 10 and 11 — two of the .env.test indexes a
      # fallback run flushes, while the leaseholder believed it was isolated. Asserting
      # the FLOOR rather than just the first block is what makes this load-bearing: slot 0
      # ([4..7]) missed the fallback by luck even before the fix, and every later slot hit it.
      skip_without_a_free_block
      env = base_env.dup

      expect(install(env)).to be_present

      fallback = described_class::STORE_ENV_VARS.map { parse(base_env.fetch(it)).fetch(:database) }
      expect(claimed.fetch(:databases).min).to be > fallback.max
      expect(claimed.fetch(:databases) & fallback).to be_empty
    end

    it "leaves the env alone when isolation is opted out of" do
      env = base_env.merge("DISABLE_TEST_REDIS_ISOLATION" => "1")

      expect(install(env)).to be_nil
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
    end

    it "does nothing outside the test environment" do
      env = base_env.merge("RAILS_ENV" => "development")
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))

      expect(install(env)).to be_nil
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
    end

    it "skips, with a reason, when the four vars point at different servers" do
      env = base_env.merge("RACK_ATTACK_REDIS_HOST" => "other-host:6379/13")
      warnings = StringIO.new

      expect(install(env, warn_io: warnings)).to be_nil
      expect(warnings.string).to include("point at 2 servers")
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
    end

    it "names the var it could not parse instead of skipping silently" do
      # A silent skip is indistinguishable from working isolation, and knowing which of
      # the two you have is the whole point of this file.
      env = base_env.merge("RPUSH_REDIS_HOST" => "redis://#{server}/12")
      warnings = StringIO.new

      expect(install(env, warn_io: warnings)).to be_nil
      expect(warnings.string).to include("RPUSH_REDIS_HOST")
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
    end

    it "skips when a store env var is blank rather than leasing a partial block" do
      env = base_env.merge("RPUSH_REDIS_HOST" => "")
      warnings = StringIO.new

      expect(install(env, warn_io: warnings)).to be_nil
      expect(warnings.string).to include("RPUSH_REDIS_HOST")
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
    end

    it "keeps refreshing the lease after a failed tick instead of letting it expire" do
      # If the refresh thread dies, the lease expires mid-run and another run leases the
      # same databases — this file's own race, with nothing to point at. So the rescue has
      # to swallow anything, and that has to be proven rather than asserted.
      skip_without_a_free_block
      env = base_env.dup
      refreshed = Queue.new
      attempt = 0

      stub_const("TestRedisIsolation::LEASE_REFRESH_SECONDS", 0.05)
      allow_any_instance_of(Redis).to receive(:eval).and_wrap_original do |original, *args|
        attempt += 1
        # First tick raises something outside any Redis error class, which is what would
        # kill a thread whose rescue lists specific classes.
        raise SocketError, "simulated resolver blip" if attempt == 1
        refreshed << true
        original.call(*args)
      end

      expect(install(env)).to be_present

      # A later tick landing at all is the proof: the thread outlived the raise.
      expect(Timeout.timeout(5) { refreshed.pop }).to be(true)
      expect(attempt).to be >= 2
    end
  end

  describe ".release_lease_at_exit" do
    it "releases the lease when the process that claimed it exits" do
      # The other half of the pid guard: a guard that never fires would strand every slot
      # until its TTL, which the fork example alone cannot tell apart from working.
      claimed = claim

      Process.wait(fork do
        described_class.send(:release_lease_at_exit, claimed)
      end)

      with_registry do |registry|
        expect(registry.get(claimed[:key])).to be_nil
      end
    end

    it "does not let a forked child release the lease its parent is still using" do
      # at_exit handlers are inherited across fork and the child holds the parent's exact
      # token, so the token compare cannot tell them apart — only the pid can.
      claimed = claim

      begin
        described_class.send(:release_lease_at_exit, claimed)
        Process.wait(fork { nil })

        with_registry do |registry|
          expect(registry.get(claimed[:key])).to eq(claimed[:token])
        end
      ensure
        described_class.release_lease(claimed)
      end
    end
  end

  describe ".reinstall_after_fork!" do
    # Spring preloads once per checkout, so the block leased at boot belongs to the server
    # and every command forked from it inherits the same one. Without this path two
    # concurrent `bin/rspec` runs flush each other's databases — this file's own race,
    # relocated from .env.test onto a leased block.
    attr_reader :claims

    before { @claims = [] }
    after { claims.each { discard(it) } }

    def capture_claims
      allow(described_class).to receive(:claim_slot).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { claims << it }
      end
    end

    def boot(env)
      described_class.install!(env:, warn_io: StringIO.new, key_prefix: test_prefix)
    end

    def fork_command(env)
      described_class.reinstall_after_fork!(env:, warn_io: StringIO.new)
    end

    it "gives a forked command its own block instead of the one it inherited" do
      skip_without_a_free_block
      allow(described_class).to receive(:reconnect_stores)
      capture_claims

      env = base_env.dup
      expect(boot(env)).to be_present
      inherited = env.dup

      expect(fork_command(env)).to be_present

      booted, forked = claims.first, claims.last
      expect(forked[:slot]).not_to eq(booted[:slot])
      expect(forked[:databases] & booted[:databases]).to be_empty
      # The point of the re-lease: the command no longer uses what it inherited.
      expect(env.fetch("REDIS_HOST")).not_to eq(inherited.fetch("REDIS_HOST"))
    end

    it "re-leases from the boot endpoints so repeated forks do not walk the floor upward" do
      # Each fork inherits an ENV already rewritten to a leased block. Deriving the floor
      # from that rather than the original .env.test values would push it up every time.
      # Asserted as "every block sits in the range the boot floor allows" rather than
      # "the blocks are contiguous": a sibling example may hold a slot in between.
      skip_without_a_free_block
      allow(described_class).to receive(:reconnect_stores)
      capture_claims

      env = base_env.dup
      expect(boot(env)).to be_present
      2.times { expect(fork_command(env)).to be_present }

      floor = described_class.reserved_databases(base_env.values_at(*described_class::STORE_ENV_VARS).map { parse(it) })
      ceiling = floor + described_class.slot_count(databases:, reserved: floor) * stores
      expect(claims.length).to eq(3)
      expect(claims.map { it.fetch(:databases).min }).to all(be_between(floor, ceiling))
      expect(claims.flat_map { it.fetch(:databases) }.uniq.length).to eq(3 * stores)
    end

    it "repoints the stores that captured a connection at boot" do
      # A fork that re-leases but keeps the parent's connections is still reading and
      # flushing the parent's databases; the lease would be bookkeeping over nothing.
      skip_without_a_free_block
      capture_claims
      original = $redis

      begin
        env = base_env.dup
        expect(boot(env)).to be_present
        expect(fork_command(env)).to be_present

        forked = claims.last
        expect($redis.connection.fetch(:db)).to eq(forked.fetch(:databases).first)
        expect(Sidekiq.redis { |connection| connection.config.db }).to eq(forked.fetch(:databases)[1])
      ensure
        $redis = original
        described_class.reconnect_stores(ENV)
      end
    end
  end

  describe "the isolation this run is itself using" do
    it "gives every Redis store a distinct database outside the .env.development block" do
      in_use = described_class::STORE_ENV_VARS.map { parse(ENV.fetch(it)).fetch(:database) }

      expect(in_use.uniq.length).to eq(stores)
      expect(in_use.min).to be >= described_class::RESERVED_DATABASES
    end

    it "points $redis, Sidekiq and Rack::Attack at three different databases" do
      # Two stores sharing a database would make one store's flushdb wipe the other's
      # keys inside a single run — the same failure as the cross-run race.
      app = $redis.connection.fetch(:db)
      sidekiq = Sidekiq.redis { |connection| connection.config.db }
      rack_attack = parse(ENV.fetch("RACK_ATTACK_REDIS_HOST")).fetch(:database)

      expect([app, sidekiq, rack_attack].uniq.length).to eq(3)
    end
  end
end
