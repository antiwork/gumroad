# frozen_string_literal: true

require "spec_helper"
require "erb"
require "yaml"

describe "config/database.yml replica routing" do
  def parsed_config
    YAML.safe_load(ERB.new(Rails.root.join("config/database.yml").read).result, aliases: true)
  end

  around do |example|
    keys = %w[
      USE_DB_WORKER_REPLICAS
      DATABASE_WORKER_REPLICA1_NAME DATABASE_WORKER_REPLICA1_USERNAME
      DATABASE_WORKER_REPLICA1_PASSWORD DATABASE_WORKER_REPLICA1_HOST
      DATABASE_REPLICA2_NAME DATABASE_REPLICA2_USERNAME
      DATABASE_REPLICA2_PASSWORD DATABASE_REPLICA2_HOST
    ]
    prior = keys.index_with { |key| ENV[key] }
    example.run
  ensure
    keys.each do |key|
      value = prior[key]
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  it "keeps a single mysql2 pool when worker replicas are off" do
    ENV.delete("USE_DB_WORKER_REPLICAS")
    production = parsed_config.fetch("production")

    expect(production["adapter"]).to eq("mysql2")
    expect(production).not_to have_key("primary")
    expect(production).not_to have_key("primary_replica")
  end

  it "registers mysql2_proxy writing and replica reading roles for production workers" do
    ENV["USE_DB_WORKER_REPLICAS"] = "true"
    ENV["DATABASE_WORKER_REPLICA1_NAME"] = "gumroad_replica"
    ENV["DATABASE_WORKER_REPLICA1_USERNAME"] = "replica_user"
    ENV["DATABASE_WORKER_REPLICA1_PASSWORD"] = "replica_pass"
    ENV["DATABASE_WORKER_REPLICA1_HOST"] = "worker-replica-1.example"

    production = parsed_config.fetch("production")
    primary = production.fetch("primary")
    replica = production.fetch("primary_replica")

    expect(primary.fetch("adapter")).to eq("mysql2_proxy")
    expect(replica.fetch("adapter")).to eq("mysql2")
    expect(replica.fetch("replica")).to eq(true)
    expect(replica.fetch("host")).to eq("worker-replica-1.example")
    expect(replica.fetch("database")).to eq("gumroad_replica")
  end

  it "registers the staging replica credentials when worker replicas are on" do
    ENV["USE_DB_WORKER_REPLICAS"] = "true"
    ENV["DATABASE_REPLICA2_NAME"] = "gumroad_staging_replica"
    ENV["DATABASE_REPLICA2_USERNAME"] = "staging_replica"
    ENV["DATABASE_REPLICA2_PASSWORD"] = "staging_pass"
    ENV["DATABASE_REPLICA2_HOST"] = "staging-replica.example"

    staging = parsed_config.fetch("staging")
    replica = staging.fetch("primary_replica")

    expect(staging.fetch("primary").fetch("adapter")).to eq("mysql2_proxy")
    expect(replica.fetch("host")).to eq("staging-replica.example")
    expect(replica.fetch("database")).to eq("gumroad_staging_replica")
  end
end
