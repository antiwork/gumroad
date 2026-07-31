# frozen_string_literal: true

require "spec_helper"

# Guards the per-run Redis database isolation added for the race in
# gumroad-private#1641: two test processes sharing one Redis database, each calling
# `flushdb` before every test, erase each other's keys mid-test.
#
# The lease examples run against the LIVE Redis this suite is already connected to,
# because the bug is a real concurrency bug and a mocked registry would prove nothing
# about it. They lease under a private key prefix and release in an `ensure`, so they
# cannot take the slot this run itself holds or leak into a sibling run.
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

  def claim(count: databases, warn_io: StringIO.new)
    described_class.claim_slot(server:, databases: count, warn_io:, key_prefix: test_prefix)
  end

  def with_registry(count = databases)
    registry = Redis.new(url: "redis://#{server}/#{described_class.registry_database(count)}")
    yield registry
  ensure
    registry&.close
  end

  def all_blocks(count = databases)
    Array.new(described_class.slot_count(databases: count)) do |slot|
      described_class.databases_for_slot(slot, databases: count)
    end
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

    it "fits only two runs on a stock 16-database server" do
      # The number that makes the compose `--databases 64` change load-bearing.
      expect(described_class.slot_count(databases: 16)).to eq(2)
      expect(described_class.slot_count(databases: 64)).to eq(14)
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
        # Two slots is a stock 16-database Redis; a third run must be told it is falling
        # back rather than silently handed a block someone else is flushing.
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
    let(:base_env) do
      {
        "RAILS_ENV" => "test",
        "REDIS_HOST" => "#{server}/10",
        "SIDEKIQ_REDIS_HOST" => "#{server}/11",
        "RPUSH_REDIS_HOST" => "#{server}/12",
        "RACK_ATTACK_REDIS_HOST" => "#{server}/13",
      }
    end

    it "rewrites all four store env vars to the one block it leased" do
      env = base_env.dup
      slot = described_class.install!(env:, warn_io: StringIO.new)

      begin
        expect(slot).to be_present

        rewritten = described_class::STORE_ENV_VARS.map { parse(env.fetch(it)) }
        expect(rewritten.map { it.fetch(:database) })
          .to eq(described_class.databases_for_slot(slot, databases:))
        expect(rewritten.map { it.fetch(:server) }.uniq).to eq([server])
      ensure
        with_registry { |registry| registry.del(described_class.lease_key(slot)) } if slot
      end
    end

    it "leaves the env alone when isolation is opted out of" do
      env = base_env.merge("DISABLE_TEST_REDIS_ISOLATION" => "1")

      expect(described_class.install!(env:, warn_io: StringIO.new)).to be_nil
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
    end

    it "does nothing outside the test environment" do
      env = base_env.merge("RAILS_ENV" => "development")
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))

      expect(described_class.install!(env:, warn_io: StringIO.new)).to be_nil
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
    end

    it "skips, with a reason, when the four vars point at different servers" do
      env = base_env.merge("RACK_ATTACK_REDIS_HOST" => "other-host:6379/13")
      warnings = StringIO.new

      expect(described_class.install!(env:, warn_io: warnings)).to be_nil
      expect(warnings.string).to include("point at 2 servers")
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
    end

    it "skips when a store env var is blank rather than leasing a partial block" do
      env = base_env.merge("RPUSH_REDIS_HOST" => "")

      expect(described_class.install!(env:, warn_io: StringIO.new)).to be_nil
      expect(env.fetch("REDIS_HOST")).to eq("#{server}/10")
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
