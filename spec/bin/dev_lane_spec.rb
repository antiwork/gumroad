# frozen_string_literal: true

require "open3"

RSpec.describe "bin/dev-lane" do
  def lane_environment(lane)
    stdout, stderr, status = Open3.capture3("bin/dev-lane", lane.to_s, "--print-env")
    environment = stdout.lines.to_h { |line| line.chomp.split("=", 2) }

    [environment, stderr, status]
  end

  it "prints today's defaults for lane 0" do
    environment, stderr, status = lane_environment(0)

    expect(status).to be_success
    expect(stderr).to be_empty
    expect(environment).to include(
      "DATABASE_NAME" => "gumroad_development",
      "MONGO_DATABASE_NAME" => "gumroad_log_development",
      "ES_INDEX_SUFFIX" => "",
      "PORT" => "3000",
      "DEV_LANE_PORT" => "3000",
      "VITE_RUBY_PORT" => "3036",
      "ANYCABLE_PORT" => "8080",
      "ANYCABLE_RPC_PORT" => "50051",
      "ANYCABLE_WEBSOCKET_URL" => "ws://cable.localhost:8080/cable",
      "REDIS_HOST" => "localhost:6379/0",
      "SIDEKIQ_REDIS_HOST" => "localhost:6379/1",
      "RPUSH_REDIS_HOST" => "localhost:6379/2",
      "RACK_ATTACK_REDIS_HOST" => "localhost:6379/3"
    )
  end

  it "prints isolated values for lane 2" do
    environment, stderr, status = lane_environment(2)

    expect(status).to be_success
    expect(stderr).to be_empty
    expect(environment).to include(
      "DATABASE_NAME" => "gumroad_development_lane2",
      "MONGO_DATABASE_NAME" => "gumroad_log_development_lane2",
      "ES_INDEX_SUFFIX" => "_lane2",
      "PORT" => "3002",
      "DEV_LANE_PORT" => "3002",
      "VITE_RUBY_PORT" => "3040",
      "ANYCABLE_PORT" => "8082",
      "ANYCABLE_RPC_PORT" => "50053",
      "ANYCABLE_WEBSOCKET_URL" => "ws://cable.localhost:8082/cable",
      "ANYCABLE_REDIS_URL" => "redis://localhost:6379/6",
      "REDIS_HOST" => "localhost:6379/6",
      "SIDEKIQ_REDIS_HOST" => "localhost:6379/7",
      "RPUSH_REDIS_HOST" => "localhost:6379/6",
      "RACK_ATTACK_REDIS_HOST" => "localhost:6379/7"
    )
  end

  it "keeps every lane clear of ports and Redis databases owned by other environments" do
    (0..3).each do |lane|
      environment, _stderr, status = lane_environment(lane)
      expect(status).to be_success

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
    environments = (0..3).map { |lane| lane_environment(lane).first }

    %w[PORT VITE_RUBY_PORT ANYCABLE_PORT ANYCABLE_RPC_PORT DATABASE_NAME MONGO_DATABASE_NAME ANYCABLE_WEBSOCKET_URL].each do |key|
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
