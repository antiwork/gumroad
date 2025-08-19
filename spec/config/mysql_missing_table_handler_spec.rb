# frozen_string_literal: true

require "spec_helper"

RSpec.describe "MySQL missing table handler" do
  it "retries query if table is missing" do
    client = ActiveRecord::Base.connection_db_config
      .configuration_hash
      .slice(*%i[host username password database port socket encoding])
      .then { |conf| Mysql2::Client.new(conf) }

    stub_const("Mysql2::Client::MISSING_TABLE_GRACE_PERIOD", 2)

    client.query("DROP TABLE IF EXISTS `foo`, `bar`")
    client.query("CREATE TABLE `bar` (id int)")
    client.query("INSERT INTO `bar`(id) VALUES (1),(2),(3)")

    Thread.new do
      sleep 1
      client.query("RENAME TABLE `bar` TO `foo`")
    end

    values = nil
    expect do
      result = client.query("SELECT id FROM `foo`")
      values = result.map { |row| row["id"].to_i }
    end.to output(/Error: missing table, retrying in/).to_stderr

    expect(values).to contain_exactly(1, 2, 3)
  ensure
    client.query("DROP TABLE IF EXISTS `foo`, `bar`")
    client.close rescue nil
  end
end
