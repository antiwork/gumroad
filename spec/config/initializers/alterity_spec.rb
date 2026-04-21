# frozen_string_literal: true

require "spec_helper"

describe "Alterity initializer" do
  it "includes --preserve-triggers in the generated command" do
    config = Alterity.config

    allow(config).to receive_messages(
      host: "db.example.com",
      port: 3306,
      username: "gumroad",
      password: "secret",
      replicas_dsns_database: "percona",
      replicas_dsns_table: "replicas_dsns",
      database: "gumroad_test"
    )

    command = config.command.call("users", "DROP COLUMN twitter_handle")

    expect(command).to include("--preserve-triggers")
  end
end
