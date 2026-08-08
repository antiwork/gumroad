# frozen_string_literal: true

require "open3"

RSpec.describe "bin/dev-lane" do
  def lane_environment(lane)
    stdout, stderr, status = Open3.capture3("bin/dev-lane", lane.to_s, "--print-env")
    environment = stdout.lines.to_h { |line| line.chomp.split("=", 2) }

    [environment, stderr, status]
  end

  it "prints the unchanged defaults for lane 0" do
    environment, stderr, status = lane_environment(0)

    expect(status).to be_success
    expect(stderr).to be_empty
    expect(environment).to include(
      "DATABASE_NAME" => "gumroad_development",
      "ES_INDEX_SUFFIX" => "",
      "PORT" => "3000",
      "REDIS_HOST" => "localhost:6379/0",
      "SIDEKIQ_REDIS_HOST" => "localhost:6379/1",
      "RPUSH_REDIS_HOST" => "localhost:6379/2",
      "RACK_ATTACK_REDIS_HOST" => "localhost:6379/3",
      "ANYCABLE_REDIS_URL" => "redis://localhost:6379/0"
    )
  end

  it "prints isolated values for lane 2" do
    environment, stderr, status = lane_environment(2)

    expect(status).to be_success
    expect(stderr).to be_empty
    expect(environment).to include(
      "DATABASE_NAME" => "gumroad_development_lane2",
      "ES_INDEX_SUFFIX" => "_lane2",
      "PORT" => "3002",
      "REDIS_HOST" => "localhost:6379/8",
      "SIDEKIQ_REDIS_HOST" => "localhost:6379/9",
      "RPUSH_REDIS_HOST" => "localhost:6379/10",
      "RACK_ATTACK_REDIS_HOST" => "localhost:6379/11",
      "ANYCABLE_REDIS_URL" => "redis://localhost:6379/8"
    )
  end

  it "rejects lanes outside the supported range" do
    _stdout, _stderr, status = Open3.capture3("bin/dev-lane", "4", "--print-env")

    expect(status.exitstatus).to eq(64)
  end

  it "rejects non-integer lanes" do
    _stdout, _stderr, status = Open3.capture3("bin/dev-lane", "two", "--print-env")

    expect(status.exitstatus).to eq(64)
  end

  it "derives disjoint service values for lanes 1 and 2" do
    lane_1, = lane_environment(1)
    lane_2, = lane_environment(2)

    database_keys = %w[DATABASE_NAME MONGO_DATABASE_NAME ES_INDEX_SUFFIX]
    redis_keys = %w[REDIS_HOST SIDEKIQ_REDIS_HOST RPUSH_REDIS_HOST RACK_ATTACK_REDIS_HOST]
    port_keys = %w[PORT VITE_RUBY_PORT ANYCABLE_PORT ANYCABLE_RPC_PORT]

    expect(lane_1.values_at(*database_keys) & lane_2.values_at(*database_keys)).to be_empty
    expect(lane_1.values_at(*redis_keys) & lane_2.values_at(*redis_keys)).to be_empty
    expect(lane_1.values_at(*port_keys) & lane_2.values_at(*port_keys)).to be_empty
  end
end
