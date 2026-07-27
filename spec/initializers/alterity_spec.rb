# frozen_string_literal: true

require "spec_helper"

# The pre-flight check is only useful if it is actually WIRED IN. These specs drive
# Alterity's real before_command hook -- the one config/initializers/alterity.rb
# installs -- rather than calling PtOscLeftoverCheck directly, so a check that exists
# but never runs would fail here.
describe "Alterity before_command pt-osc pre-flight" do
  let(:connection) { ActiveRecord::Base.connection }
  let(:database) { connection.current_database }
  let(:table) { "alterity_hook_fixture" }

  # The shape Alterity's config.command actually produces, trimmed to the parts the
  # hook reads. Built from the real template so the table-name parse is exercised
  # against a realistic string, not a hand-written one.
  let(:command) do
    Alterity.send(:config).command.call(table, %("ADD INDEX index_foo (bar)")).to_s
  end

  before do
    cleanup_artifacts_for(table)
    connection.execute("DROP TABLE IF EXISTS `#{table}`")
    connection.execute("CREATE TABLE `#{table}` (id INT PRIMARY KEY)")
  end

  after do
    cleanup_artifacts_for(table)
    connection.execute("DROP TABLE IF EXISTS `#{table}`")
  end

  # Schema objects are not rolled back by DatabaseCleaner, so anything an example
  # creates has to be dropped explicitly or it is still there for the next one.
  def cleanup_artifacts_for(target)
    %w[ins upd del].each do |suffix|
      connection.execute("DROP TRIGGER IF EXISTS `pt_osc_#{database}_#{target}_#{suffix}`")
    end
    connection.execute("DROP TABLE IF EXISTS `_#{target}_new`")
  end

  def run_hook(with: command)
    Alterity.send(:config).before_command.call(with)
  end

  it "extracts the table name from the command Alterity builds" do
    expect(command).to include("t=#{table}")
  end

  # The command carries `--recursion-method 'dsn=D=percona,t=replicas_dsns'` BEFORE the
  # `D=<db>,t=<table>` argument that names the table being altered. A `t=` match that is
  # not anchored on the whole `D=…,t=…` argument reads `replicas_dsns` instead, checks
  # the wrong table, and reports the migration clear while the real table is blocked.
  # This spec exists because that is exactly what the first version of the hook did.
  it "does not mistake the recursion-method DSN's table for the altered table" do
    expect(command).to match(/t=replicas_dsns.*t=#{table}/)

    connection.execute(<<~SQL.squish)
      CREATE TRIGGER `pt_osc_#{database}_#{table}_ins`
      AFTER INSERT ON `#{table}` FOR EACH ROW SET @alterity_hook_noop = 1
    SQL

    expect { run_hook }
      .to raise_error(PtOscLeftoverCheck::LeftoversPresent, /on `#{table}`/)
  end

  it "allows the command through on a clean table" do
    expect { run_hook }.not_to raise_error
  end

  it "refuses the command when the table carries leftover pt-osc triggers" do
    connection.execute(<<~SQL.squish)
      CREATE TRIGGER `pt_osc_#{database}_#{table}_ins`
      AFTER INSERT ON `#{table}` FOR EACH ROW SET @alterity_hook_noop = 1
    SQL

    expect { run_hook }
      .to raise_error(PtOscLeftoverCheck::LeftoversPresent, /Refusing to run an online schema change/)
  end

  # If the command template ever changes shape, the table-name parse returns nothing.
  # Skipping the check is the right failure mode there: refusing a migration on a
  # table we could not identify would block healthy migrations, which is worse than
  # not checking.
  it "skips the check rather than guessing when the command has no table" do
    expect { run_hook(with: "pt-online-schema-change --execute --alter \"ADD INDEX x (y)\"") }
      .not_to raise_error
  end

  # The hook's original job -- logging the command -- has to keep working.
  it "still logs the migration it is about to run" do
    expect(Rails.logger).to receive(:info).with(/\[Alterity\].*Will execute migration/)

    run_hook
  end
end
