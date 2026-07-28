# frozen_string_literal: true

require "spec_helper"

describe PtOscLeftovers do
  # These specs create REAL pt-osc-shaped artifacts in the test database rather
  # than stubbing information_schema, because the whole value of the check is that
  # it recognises what pt-osc actually leaves behind. A stub would pass just as
  # happily against a pattern that matches nothing in MySQL.
  let(:connection) { ActiveRecord::Base.connection }
  let(:database) { connection.current_database }

  def create_shadow_table(original)
    connection.execute("CREATE TABLE `_#{original}_new` LIKE `#{original}`")
  end

  def create_pt_osc_triggers(original)
    %w[ins upd del].each do |event|
      # Bodies do not matter -- pt-osc's real ones mirror writes into the shadow
      # table. What is being tested is that the artifacts are FOUND, so these are
      # the cheapest triggers that can exist under the right names.
      connection.execute(<<~SQL.squish)
        CREATE TRIGGER `pt_osc_#{database}_#{original}_#{event}`
        AFTER #{{ "ins" => "INSERT", "upd" => "UPDATE", "del" => "DELETE" }[event]} ON `#{original}`
        FOR EACH ROW BEGIN SET @pt_osc_spec_noop = 1; END
      SQL
    end
  end

  after do
    connection.execute("DROP TABLE IF EXISTS `_pt_osc_spec_targets_new`")
    connection.execute("DROP TABLE IF EXISTS `_pt_osc_spec_orphans_new`")
    connection.execute("DROP TABLE IF EXISTS `_pt_osc_spec_others_new`")
    %w[ins upd del].each do |event|
      connection.execute("DROP TRIGGER IF EXISTS `pt_osc_#{database}_pt_osc_spec_targets_#{event}`")
    end
    connection.execute("DROP TABLE IF EXISTS `pt_osc_spec_targets`")
    connection.execute("DROP TABLE IF EXISTS `pt_osc_spec_others`")
  end

  before do
    connection.execute("DROP TABLE IF EXISTS `pt_osc_spec_targets`")
    connection.execute("CREATE TABLE `pt_osc_spec_targets` (id INT PRIMARY KEY, name VARCHAR(20))")
    connection.execute("DROP TABLE IF EXISTS `pt_osc_spec_others`")
    connection.execute("CREATE TABLE `pt_osc_spec_others` (id INT PRIMARY KEY)")
  end

  describe ".all" do
    it "is empty on a clean database" do
      expect(described_class.all).to be_empty
    end

    it "reports a table whose pt-osc triggers were left behind" do
      create_pt_osc_triggers("pt_osc_spec_targets")

      leftovers = described_class.all

      expect(leftovers.size).to eq(1)
      expect(leftovers.first.table).to eq("pt_osc_spec_targets")
      expect(leftovers.first.triggers.sort).to eq(
        %w[ins upd del].sort.map { |event| "pt_osc_#{database}_pt_osc_spec_targets_#{event}" }.sort
      )
      expect(leftovers.first.shadow_tables).to be_empty
    end

    it "reports a table whose pt-osc shadow table was left behind" do
      create_shadow_table("pt_osc_spec_targets")

      leftovers = described_class.all

      expect(leftovers.size).to eq(1)
      expect(leftovers.first.table).to eq("pt_osc_spec_targets")
      expect(leftovers.first.shadow_tables).to eq(["_pt_osc_spec_targets_new"])
      expect(leftovers.first.triggers).to be_empty
    end

    it "reports triggers and the shadow table as one entry for the same table" do
      create_pt_osc_triggers("pt_osc_spec_targets")
      create_shadow_table("pt_osc_spec_targets")

      leftovers = described_class.all

      expect(leftovers.size).to eq(1)
      expect(leftovers.first.triggers.size).to eq(3)
      expect(leftovers.first.shadow_tables).to eq(["_pt_osc_spec_targets_new"])
    end

    it "ignores a shadow table whose original no longer exists" do
      # `_x_new` with no `x` is not an interrupted schema change on a live table,
      # and blocking a deploy on it would be an alarm nobody can clear by fixing
      # what is being complained about.
      connection.execute("CREATE TABLE `_pt_osc_spec_orphans_new` (id INT PRIMARY KEY)")

      expect(described_class.all).to be_empty
    end

    it "ignores application tables that merely end in _new" do
      connection.execute("DROP TABLE IF EXISTS `pt_osc_spec_looks_new`")
      connection.execute("CREATE TABLE `pt_osc_spec_looks_new` (id INT PRIMARY KEY)")

      expect(described_class.all).to be_empty
    ensure
      connection.execute("DROP TABLE IF EXISTS `pt_osc_spec_looks_new`")
    end

    it "ignores triggers that are not pt-osc's" do
      connection.execute(<<~SQL.squish)
        CREATE TRIGGER `pt_osc_spec_unrelated_trigger`
        AFTER INSERT ON `pt_osc_spec_targets`
        FOR EACH ROW BEGIN SET @pt_osc_spec_noop = 1; END
      SQL

      expect(described_class.all).to be_empty
    ensure
      connection.execute("DROP TRIGGER IF EXISTS `pt_osc_spec_unrelated_trigger`")
    end

    it "attributes a trigger to the table it is installed on, not to a name split on underscores" do
      # The altered table's own name contains underscores, so anything that
      # recovered it by splitting `pt_osc_<db>_<table>_<event>` would get it wrong.
      create_pt_osc_triggers("pt_osc_spec_targets")

      expect(described_class.all.first.table).to eq("pt_osc_spec_targets")
    end
  end

  describe ".leftovers_for" do
    it "finds leftovers for the named table" do
      create_pt_osc_triggers("pt_osc_spec_targets")

      expect(described_class.leftovers_for("pt_osc_spec_targets").triggers.size).to eq(3)
      expect(described_class.leftovers_for(:pt_osc_spec_targets)).to be_present
    end

    it "is nil for a table with no leftovers" do
      create_pt_osc_triggers("pt_osc_spec_targets")

      expect(described_class.leftovers_for("purchases")).to be_nil
    end
  end

  describe ".blocking?" do
    it "is true when triggers were left behind, since those are what pt-osc trips over" do
      create_pt_osc_triggers("pt_osc_spec_targets")

      expect(described_class.blocking?(described_class.all)).to be(true)
    end

    it "is false for a shadow table with no triggers, which pt-osc renames around" do
      create_shadow_table("pt_osc_spec_targets")

      expect(described_class.blocking?(described_class.all)).to be(false)
    end

    it "is true when any table has triggers, even if another has only a shadow table" do
      create_pt_osc_triggers("pt_osc_spec_targets")
      connection.execute("CREATE TABLE `_pt_osc_spec_others_new` LIKE `pt_osc_spec_others`")

      expect(described_class.blocking?(described_class.all)).to be(true)
    end
  end

  describe ".failure_message" do
    it "names the tables, the artifacts, and the cleanup order" do
      create_pt_osc_triggers("pt_osc_spec_targets")
      create_shadow_table("pt_osc_spec_targets")

      message = described_class.failure_message(described_class.all)

      expect(message).to include("pt_osc_spec_targets")
      expect(message).to include("_pt_osc_spec_targets_new")
      expect(message).to include("drop the triggers FIRST")
    end

    it "warns against the schema_migrations workaround that caused the original incident" do
      create_pt_osc_triggers("pt_osc_spec_targets")

      expect(described_class.failure_message(described_class.all))
        .to include("Do NOT work around this by inserting the migration's version into schema_migrations")
    end

    it "documents the escape hatch for a genuinely in-flight run" do
      create_shadow_table("pt_osc_spec_targets")

      expect(described_class.failure_message(described_class.all)).to include("ALLOW_PT_OSC_LEFTOVERS=1")
    end

    it "does not blame triggers when only a shadow table was left behind" do
      # A shadow table with no triggers is a different problem: nothing is
      # duplicating writes, and there are no triggers to drop. Saying otherwise
      # sends whoever reads this looking for something that is not there.
      create_shadow_table("pt_osc_spec_targets")

      message = described_class.failure_message(described_class.all)

      expect(message).to include("no leftover triggers")
      expect(message).to include("Drop the leftover shadow table")
      expect(message).not_to include("cannot create triggers that already exist")
      expect(message).not_to include("drop the triggers FIRST")
      expect(message).not_to include("duplicating every write")
    end

    it "does not say it is refusing to migrate when nothing is blocking the migration" do
      # pt-osc renames around a stray shadow table -- Ershad's reproduction on
      # gumroad-private#1417 shows it creating and altering `__purchases_new` with
      # `_purchases_new` already present, failing only at trigger creation. So a
      # shadow table alone is not a reason to refuse a deploy.
      create_shadow_table("pt_osc_spec_targets")

      message = described_class.failure_message(described_class.all)

      expect(message).to start_with("Found:")
      expect(message).not_to include("Refusing to migrate")
      expect(message).to include("schema changes are not blocked")
    end

    it "says it is refusing to migrate when triggers are present" do
      create_pt_osc_triggers("pt_osc_spec_targets")

      expect(described_class.failure_message(described_class.all)).to start_with("Refusing to migrate")
    end

    it "explains each table on its own terms when one has triggers and another does not" do
      create_pt_osc_triggers("pt_osc_spec_targets")
      connection.execute("CREATE TABLE `_pt_osc_spec_others_new` LIKE `pt_osc_spec_others`")

      message = described_class.failure_message(described_class.all)

      expect(message).to include("Any schema change to pt_osc_spec_targets will fail")
      expect(message).to include("pt_osc_spec_others carries a leftover shadow table but no leftover triggers")
      expect(message).to include("drop its triggers FIRST")
    end
  end
end
