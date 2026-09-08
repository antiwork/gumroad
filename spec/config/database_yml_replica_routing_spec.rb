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

  it "keeps development and test on one plain pool by default" do
    ENV.delete("USE_DB_WORKER_REPLICAS")
    config = parsed_config

    %w[development test].each do |env|
      expect(config.fetch(env)["adapter"]).to eq("mysql2")
      expect(config.fetch(env)).not_to have_key("primary_replica")
    end
  end

  # The flag used to abort boot outside staging/production, which is why the dev
  # Procfiles cannot set it and why nothing but production exercises the routing.
  it "expands development and test into the same role pair, on the local database" do
    ENV["USE_DB_WORKER_REPLICAS"] = "true"
    config = parsed_config

    %w[development test].each do |env|
      expect(config.fetch(env).fetch("primary").fetch("adapter")).to eq("mysql2_proxy")
      replica = config.fetch(env).fetch("primary_replica")
      expect(replica.fetch("adapter")).to eq("mysql2")
      expect(replica.fetch("replica")).to eq(true)
      expect(replica.fetch("host")).to eq(ENV.fetch("DATABASE_HOST"))
      expect(replica.fetch("database")).to eq(config.fetch(env).fetch("primary").fetch("database"))
    end
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

  it "falls back to the primary as a group when the environment has no replica secret" do
    ENV["USE_DB_WORKER_REPLICAS"] = "true"
    %w[NAME USERNAME PASSWORD HOST].each { |key| ENV.delete("DATABASE_REPLICA2_#{key}") }

    replica = parsed_config.fetch("staging").fetch("primary_replica")

    # A nil host makes every proxy-routed read attempt a localhost connect first,
    # and falling back per key would pair a replica host with primary credentials.
    expect(replica.fetch("host")).to eq(ENV.fetch("DATABASE_HOST"))
    expect(replica.fetch("database")).to eq(ENV.fetch("DATABASE_NAME"))
    expect(replica.fetch("username")).to eq(ENV.fetch("DATABASE_USERNAME"))
  end

  # Half a group used to raise KeyError on the NAME fetch. One ERB pass renders
  # every environment, so this aborted boot even for processes that never read
  # the environment holding the incomplete group.
  %w[NAME USERNAME HOST].each do |only_key|
    it "falls back to the primary when only DATABASE_REPLICA2_#{only_key} is set" do
      ENV["USE_DB_WORKER_REPLICAS"] = "true"
      %w[NAME USERNAME PASSWORD HOST].each { |key| ENV.delete("DATABASE_REPLICA2_#{key}") }
      ENV["DATABASE_REPLICA2_#{only_key}"] = "partial-staging"

      replica = parsed_config.fetch("staging").fetch("primary_replica")

      expect(replica.fetch("host")).to eq(ENV.fetch("DATABASE_HOST"))
      expect(replica.fetch("database")).to eq(ENV.fetch("DATABASE_NAME"))
      expect(replica.fetch("username")).to eq(ENV.fetch("DATABASE_USERNAME"))
    end
  end

  it "keeps a complete replica group when another environment's group is incomplete" do
    ENV["USE_DB_WORKER_REPLICAS"] = "true"
    ENV["DATABASE_WORKER_REPLICA1_NAME"] = "gumroad_replica"
    ENV["DATABASE_WORKER_REPLICA1_USERNAME"] = "replica_user"
    ENV["DATABASE_WORKER_REPLICA1_PASSWORD"] = "replica_pass"
    ENV["DATABASE_WORKER_REPLICA1_HOST"] = "worker-replica-1.example"
    %w[NAME USERNAME PASSWORD].each { |key| ENV.delete("DATABASE_REPLICA2_#{key}") }
    ENV["DATABASE_REPLICA2_HOST"] = "partial-staging.example"

    config = parsed_config

    expect(config.fetch("production").fetch("primary_replica").fetch("host")).to eq("worker-replica-1.example")
    expect(config.fetch("staging").fetch("primary_replica").fetch("host")).to eq(ENV.fetch("DATABASE_HOST"))
  end

  it "ignores retired worker replica hosts in lag monitoring" do
    constants = Rails.root.join("config/initializers/004_constants.rb").read
    definition = constants[/REPLICAS_HOSTS = .*?(?=\n\n)/m]
    hosts = {
      "DATABASE_HOST" => "primary.example",
      "DATABASE_WORKER_REPLICA1_HOST" => "worker.example",
      "DATABASE_WORKER_REPLICA2_HOST" => "retired.example",
      "DATABASE_REPLICA2_HOST" => "staging.example"
    }
    allow(ENV).to receive(:[]).and_call_original
    hosts.each { |key, value| allow(ENV).to receive(:[]).with(key).and_return(value) }

    config = Module.new
    config.module_eval(definition)

    expect(config.const_get(:REPLICAS_HOSTS)).to include("worker.example", "staging.example")
    expect(config.const_get(:REPLICAS_HOSTS)).not_to include("retired.example", "primary.example")
  end

  it "keeps branch-app staging on mysql2 without the worker flag" do
    ENV.delete("USE_DB_WORKER_REPLICAS")
    staging = YAML.safe_load(
      ERB.new(Rails.root.join("config/database.branch-app.yml").read).result,
      aliases: true
    ).fetch("staging")

    expect(staging.fetch("adapter")).to eq("mysql2")
    expect(staging).not_to have_key("primary_replica")
  end

  it "gives branch-app staging a same-host replica so connects_to can boot" do
    ENV["USE_DB_WORKER_REPLICAS"] = "true"
    staging = YAML.safe_load(
      ERB.new(Rails.root.join("config/database.branch-app.yml").read).result,
      aliases: true
    ).fetch("staging")

    expect(staging.fetch("primary").fetch("adapter")).to eq("mysql2_proxy")
    replica = staging.fetch("primary_replica")
    expect(replica.fetch("adapter")).to eq("mysql2")
    expect(replica.fetch("replica")).to eq(true)
    expect(replica.fetch("host")).to eq(ENV.fetch("DATABASE_HOST"))
  end
end
