# frozen_string_literal: true

require "spec_helper"

describe PtOscLeftoverCheck do
  # These specs create REAL triggers and REAL shadow tables in the test database,
  # rather than stubbing the information_schema queries. The check exists because of
  # how MySQL names and reports these objects, so a stubbed version would only assert
  # that the code calls the methods it calls, and would keep passing if the naming
  # convention or the lookups were wrong.
  let(:connection) { ActiveRecord::Base.connection }
  let(:database) { connection.current_database }

  # A table of our own to hang the artifacts off, so nothing here touches a table any
  # other spec depends on. `alerts` is not a real Gumroad table; the name only has to
  # be unique within the run.
  let(:table) { "pt_osc_check_fixture" }

  # Every artifact any example can create is dropped here, for EVERY example.
  #
  # This is deliberately over-broad rather than scoped per context. The objects under
  # test are schema objects, which DatabaseCleaner does not roll back, so anything an
  # example leaves behind is still there for the next example -- and a leaked shadow
  # table makes a later "this should be clean" example fail for a reason that has
  # nothing to do with the code. Listing every name in one place is what keeps the
  # suite order-independent.
  def cleanup_artifacts_for(target)
    %w[ins upd del].each do |suffix|
      connection.execute("DROP TRIGGER IF EXISTS `pt_osc_#{database}_#{target}_#{suffix}`")
      connection.execute("DROP TRIGGER IF EXISTS `pt_osc_#{database}_#{target}_other_#{suffix}`")
    end
    connection.execute("DROP TABLE IF EXISTS `___#{target}_new`")
    connection.execute("DROP TABLE IF EXISTS `__#{target}_new`")
    connection.execute("DROP TABLE IF EXISTS `_#{target}_new`")
    connection.execute("DROP TABLE IF EXISTS `#{target}_new`")
  end

  before do
    cleanup_artifacts_for("#{table}_extra")
    cleanup_artifacts_for(table)
    connection.execute("DROP TABLE IF EXISTS `#{table}_extra`")
    connection.execute("DROP TABLE IF EXISTS `#{table}`")
    connection.execute("CREATE TABLE `#{table}` (id INT PRIMARY KEY, value INT)")
  end

  after do
    cleanup_artifacts_for("#{table}_extra")
    cleanup_artifacts_for(table)
    connection.execute("DROP TABLE IF EXISTS `#{table}_extra`")
    connection.execute("DROP TABLE IF EXISTS `#{table}`")
  end

  def create_leftover_triggers(target = table, suffixes: %w[ins upd del])
    suffixes.each do |suffix|
      event = { "ins" => "INSERT", "upd" => "UPDATE", "del" => "DELETE" }.fetch(suffix)
      connection.execute(<<~SQL.squish)
        CREATE TRIGGER `pt_osc_#{database}_#{target}_#{suffix}`
        AFTER #{event} ON `#{target}` FOR EACH ROW SET @pt_osc_check_noop = 1
      SQL
    end
  end

  def create_shadow_table(name)
    connection.execute("CREATE TABLE `#{name}` (id INT PRIMARY KEY, value INT)")
  end

  describe ".assert_absent!" do
    it "passes on a clean table" do
      expect { described_class.assert_absent!(table) }.not_to raise_error
    end

    it "raises when the pt-osc trigger set is still present" do
      create_leftover_triggers

      expect { described_class.assert_absent!(table) }
        .to raise_error(described_class::LeftoversPresent, /Refusing to run an online schema change on `#{table}`/)
    end

    it "raises when only the shadow table is left behind" do
      create_shadow_table("_#{table}_new")

      expect { described_class.assert_absent!(table) }
        .to raise_error(described_class::LeftoversPresent, /Leftover shadow table\(s\)/)
    end

    # An abandoned run can leave a partial trigger set: pt-osc creates the three
    # triggers one at a time, so it can die between them. Any one of them is enough to
    # make the next run fail, so the check must not require all three.
    it "raises on a partial trigger set" do
      create_leftover_triggers(suffixes: %w[del])

      expect { described_class.assert_absent!(table) }
        .to raise_error(described_class::LeftoversPresent, /pt_osc_#{database}_#{table}_del/)
    end

    it "names every leftover artifact it found" do
      create_leftover_triggers
      create_shadow_table("_#{table}_new")
      create_shadow_table("__#{table}_new")

      error = nil
      begin
        described_class.assert_absent!(table)
      rescue described_class::LeftoversPresent => e
        error = e
      end

      expect(error).to be_present
      %w[ins upd del].each do |suffix|
        expect(error.message).to include("pt_osc_#{database}_#{table}_#{suffix}")
      end
      # Both generations of shadow table: pt-osc prepends another underscore for each
      # name already taken, so leftovers can stack, and a message that mentions only
      # the first one sends the operator back for a second pass.
      expect(error.message).to include("#{database}._#{table}_new")
      expect(error.message).to include("#{database}.__#{table}_new")
    end

    it "explains that triggers must be dropped before the shadow table" do
      create_leftover_triggers
      create_shadow_table("_#{table}_new")

      expect { described_class.assert_absent!(table) }
        .to raise_error(described_class::LeftoversPresent, /dropped\s+BEFORE the shadow table/)
    end

    it "does not modify anything" do
      create_leftover_triggers
      create_shadow_table("_#{table}_new")

      expect { described_class.assert_absent!(table) rescue nil }
        .not_to change { [trigger_names_for(table).sort, connection.table_exists?("_#{table}_new")] }
    end

    it "accepts a backtick-quoted table name" do
      create_leftover_triggers

      expect { described_class.assert_absent!("`#{table}`") }
        .to raise_error(described_class::LeftoversPresent)
    end

    # The lookups have to be anchored on the exact table name. A LIKE/prefix match
    # would let one table's leftovers block migrations on a different table whose name
    # merely starts the same way — blocking a healthy migration is its own outage, so
    # these two cases matter as much as the positive ones.
    context "with a similarly-named neighbouring table" do
      let(:neighbour) { "#{table}_extra" }

      before do
        connection.execute("CREATE TABLE `#{neighbour}` (id INT PRIMARY KEY)")
      end

      it "does not block the shorter table because of the neighbour's triggers" do
        create_leftover_triggers(neighbour)

        expect { described_class.assert_absent!(table) }.not_to raise_error
      end

      it "does not block the neighbour because of the shorter table's triggers" do
        create_leftover_triggers

        expect { described_class.assert_absent!(neighbour) }.not_to raise_error
      end

      it "does not treat the neighbour's shadow table as this table's" do
        create_shadow_table("_#{neighbour}_new")

        expect { described_class.assert_absent!(table) }.not_to raise_error
      end
    end

    # `<table>_new` with no leading underscore is not a pt-osc artifact — pt-osc always
    # prefixes at least one — so a real application table by that name must not be read
    # as a leftover.
    it "ignores a table named <table>_new with no leading underscore" do
      create_shadow_table("#{table}_new")

      expect { described_class.assert_absent!(table) }.not_to raise_error
    end

    # A trigger whose name merely starts with pt-osc's prefix is not one of the three
    # names pt-osc will try to create, so it cannot cause the collision this check is
    # about.
    it "ignores triggers outside the three names pt-osc uses" do
      connection.execute(<<~SQL.squish)
        CREATE TRIGGER `pt_osc_#{database}_#{table}_other_ins`
        AFTER INSERT ON `#{table}` FOR EACH ROW SET @pt_osc_check_noop = 1
      SQL

      expect { described_class.assert_absent!(table) }.not_to raise_error
    end
  end

  def trigger_names_for(target)
    connection.select_values(<<~SQL.squish)
      SELECT TRIGGER_NAME FROM information_schema.triggers
      WHERE TRIGGER_SCHEMA = #{connection.quote(database)}
        AND EVENT_OBJECT_TABLE = #{connection.quote(target)}
    SQL
  end
end
