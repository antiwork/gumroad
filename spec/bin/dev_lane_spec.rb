# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "bin/dev-lane" do
  EXPECTED_LANE_ENVIRONMENTS = {
    0 => {
      "PORT" => "3000",
      "DEV_LANE_PORT" => "3000",
      "VITE_RUBY_PORT" => "3036",
      "DATABASE_NAME" => "gumroad_development",
      "MONGO_DATABASE_NAME" => "gumroad_log_development",
      "ES_INDEX_SUFFIX" => "",
      "REDIS_HOST" => "localhost:6379/0",
      "SIDEKIQ_REDIS_HOST" => "localhost:6379/1",
      "RPUSH_REDIS_HOST" => "localhost:6379/2",
      "RACK_ATTACK_REDIS_HOST" => "localhost:6379/3",
      "ANYCABLE_PORT" => "8080",
      "ANYCABLE_RPC_PORT" => "50051",
      "ANYCABLE_REDIS_URL" => "redis://localhost:6379/0",
      "ANYCABLE_WEBSOCKET_URL" => "ws://cable.localhost:8080/cable",
      "ANYCABLE_REDIS_CHANNEL" => "__anycable__",
      "PIDFILE" => "tmp/pids/server-lane0.pid"
    },
    1 => {
      "PORT" => "3001",
      "DEV_LANE_PORT" => "3001",
      "VITE_RUBY_PORT" => "3038",
      "DATABASE_NAME" => "gumroad_development_lane1",
      "MONGO_DATABASE_NAME" => "gumroad_log_development_lane1",
      "ES_INDEX_SUFFIX" => "_lane1",
      "REDIS_HOST" => "localhost:6379/4",
      "SIDEKIQ_REDIS_HOST" => "localhost:6379/5",
      "RPUSH_REDIS_HOST" => "localhost:6379/4",
      "RACK_ATTACK_REDIS_HOST" => "localhost:6379/5",
      "ANYCABLE_PORT" => "8081",
      "ANYCABLE_RPC_PORT" => "50052",
      "ANYCABLE_REDIS_URL" => "redis://localhost:6379/4",
      "ANYCABLE_WEBSOCKET_URL" => "ws://cable.localhost:8081/cable",
      "ANYCABLE_REDIS_CHANNEL" => "__anycable___lane1",
      "PIDFILE" => "tmp/pids/server-lane1.pid"
    },
    2 => {
      "PORT" => "3002",
      "DEV_LANE_PORT" => "3002",
      "VITE_RUBY_PORT" => "3040",
      "DATABASE_NAME" => "gumroad_development_lane2",
      "MONGO_DATABASE_NAME" => "gumroad_log_development_lane2",
      "ES_INDEX_SUFFIX" => "_lane2",
      "REDIS_HOST" => "localhost:6379/6",
      "SIDEKIQ_REDIS_HOST" => "localhost:6379/7",
      "RPUSH_REDIS_HOST" => "localhost:6379/6",
      "RACK_ATTACK_REDIS_HOST" => "localhost:6379/7",
      "ANYCABLE_PORT" => "8082",
      "ANYCABLE_RPC_PORT" => "50053",
      "ANYCABLE_REDIS_URL" => "redis://localhost:6379/6",
      "ANYCABLE_WEBSOCKET_URL" => "ws://cable.localhost:8082/cable",
      "ANYCABLE_REDIS_CHANNEL" => "__anycable___lane2",
      "PIDFILE" => "tmp/pids/server-lane2.pid"
    },
    3 => {
      "PORT" => "3003",
      "DEV_LANE_PORT" => "3003",
      "VITE_RUBY_PORT" => "3042",
      "DATABASE_NAME" => "gumroad_development_lane3",
      "MONGO_DATABASE_NAME" => "gumroad_log_development_lane3",
      "ES_INDEX_SUFFIX" => "_lane3",
      "REDIS_HOST" => "localhost:6379/8",
      "SIDEKIQ_REDIS_HOST" => "localhost:6379/9",
      "RPUSH_REDIS_HOST" => "localhost:6379/8",
      "RACK_ATTACK_REDIS_HOST" => "localhost:6379/9",
      "ANYCABLE_PORT" => "8083",
      "ANYCABLE_RPC_PORT" => "50054",
      "ANYCABLE_REDIS_URL" => "redis://localhost:6379/8",
      "ANYCABLE_WEBSOCKET_URL" => "ws://cable.localhost:8083/cable",
      "ANYCABLE_REDIS_CHANNEL" => "__anycable___lane3",
      "PIDFILE" => "tmp/pids/server-lane3.pid"
    }
  }.freeze

  def lane_environment(lane)
    stdout, stderr, status = Open3.capture3("bin/dev-lane", lane.to_s, "--print-env")
    environment = stdout.lines.to_h { |line| line.chomp.split("=", 2) }

    [environment, stderr, status]
  end

  EXPECTED_LANE_ENVIRONMENTS.each do |lane, expected|
    it "prints the derived environment for lane #{lane}" do
      environment, stderr, status = lane_environment(lane)

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(environment).to eq(expected)
    end
  end

  it "exports every printed variable to the child process, not just locals" do
    # --print-env prints shell locals, so it cannot prove a variable was exported.
    # Run the real script against a stub bin/dev that dumps its own environment.
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.cp("bin/dev-lane", File.join(dir, "bin/dev-lane"))
      stub = File.join(dir, "bin/dev")
      File.write(stub, "#!/bin/sh\nenv\n")
      FileUtils.chmod(0o755, [stub, File.join(dir, "bin/dev-lane")])

      stdout, _stderr, status = Open3.capture3("bin/dev-lane", "2", chdir: dir)
      expect(status).to be_success

      # `env` output can carry multi-line values (exported shell functions); keep
      # only well-formed KEY=VALUE lines.
      child_environment = stdout.lines.filter_map do |line|
        line.chomp.split("=", 2) if line.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
      end.to_h
      expect(child_environment).to include(EXPECTED_LANE_ENVIRONMENTS.fetch(2))
    end
  end

  it "keeps every lane clear of ports and Redis databases owned by other environments" do
    EXPECTED_LANE_ENVIRONMENTS.each do |lane, environment|
      # 3037 is the test environment's Vite port (config/vite.json).
      expect(environment.fetch("VITE_RUBY_PORT")).not_to eq("3037")

      # Databases 10+ belong to the test suite: 10-13 are .env.test's fallback
      # block and leases start at 14 (config/test_redis_isolation.rb). Both are
      # flushed before every example.
      %w[REDIS_HOST SIDEKIQ_REDIS_HOST RPUSH_REDIS_HOST RACK_ATTACK_REDIS_HOST].each do |key|
        database = environment.fetch(key).split("/").last.to_i
        expect(database).to be < 10, "lane #{lane} #{key} uses test-owned Redis db #{database}"
      end
    end
  end

  it "derives disjoint service values across all lanes" do
    environments = EXPECTED_LANE_ENVIRONMENTS.values

    %w[PORT VITE_RUBY_PORT ANYCABLE_PORT ANYCABLE_RPC_PORT DATABASE_NAME MONGO_DATABASE_NAME ANYCABLE_WEBSOCKET_URL ANYCABLE_REDIS_CHANNEL PIDFILE].each do |key|
      values = environments.map { |environment| environment.fetch(key) }
      expect(values.uniq.length).to eq(4), "#{key} collides across lanes: #{values}"
    end

    redis_databases = environments.map do |environment|
      %w[REDIS_HOST SIDEKIQ_REDIS_HOST RPUSH_REDIS_HOST RACK_ATTACK_REDIS_HOST].map { |key| environment.fetch(key) }.uniq.sort
    end
    redis_databases.combination(2) do |a, b|
      expect(a & b).to be_empty, "Redis databases shared across lanes: #{a & b}"
    end
  end

  it "rejects lanes outside the supported range" do
    _stdout, stderr, status = Open3.capture3("bin/dev-lane", "4", "--print-env")

    expect(status.exitstatus).to eq(64)
    expect(stderr).to include("Usage:")
  end

  it "rejects non-integer lanes" do
    _stdout, stderr, status = Open3.capture3("bin/dev-lane", "two", "--print-env")

    expect(status.exitstatus).to eq(64)
    expect(stderr).to include("Usage:")
  end
end
