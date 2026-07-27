# frozen_string_literal: true

# Refuses to run an online schema change against a table that is still carrying the
# leftovers of an earlier, abandoned one.
#
# Why this exists: schema changes to large tables go through the Alterity gem, which
# hands every ALTER to pt-online-schema-change. pt-osc works by creating a shadow
# copy of the table (`_<table>_new`) plus three triggers that mirror every write into
# it, copying the existing rows across in batches, and finally swapping the two
# tables. Its trigger names are derived from the database and table name with nothing
# to make them unique per run:
#
#   pt_osc_<database>_<table>_ins
#   pt_osc_<database>_<table>_upd
#   pt_osc_<database>_<table>_del
#
# So if a previous pt-osc run was killed without cleaning up after itself, its
# triggers keep those names forever, and the NEXT pt-osc run on that table fails
# immediately with "Trigger already exists". That is the whole failure: no migration
# on that table can succeed again until somebody drops the leftovers by hand.
#
# What makes it worth a pre-flight check rather than letting pt-osc fail is how the
# failure presents. pt-osc drops its own scratch table on the way out and leaves the
# pre-existing triggers untouched, so it fails in seconds and leaves NO trace in the
# database — and the error text ("Trigger already exists") describes the symptom
# without saying anything about what to do. In production this once cost a hung
# deploy and a migration recorded as applied that had never run; see
# gumroad-private#1417.
#
# This check turns that into an up-front, actionable refusal: it names the leftover
# artifacts and says what has to happen before the migration can be retried. It is
# purely diagnostic — it never drops or modifies anything, because dropping a live
# trigger set on a large table is a destructive production operation that belongs
# with a human who has decided to do it deliberately.
class PtOscLeftoverCheck
  # Raised instead of running pt-osc. The message is the whole point of the class, so
  # it names every artifact found and the order to remove them in.
  class LeftoversPresent < StandardError; end

  TRIGGER_SUFFIXES = %w[ins upd del].freeze

  def self.assert_absent!(table, connection: ActiveRecord::Base.connection)
    new(table, connection:).assert_absent!
  end

  def initialize(table, connection: ActiveRecord::Base.connection)
    # Alterity strips backticks before calling us, but a caller reaching this class
    # directly may not have, and a quoted name would silently match nothing.
    @table = table.to_s.delete("`")
    @connection = connection
  end

  def assert_absent!
    leftover_triggers = find_leftover_triggers
    shadow_tables = find_shadow_tables

    return if leftover_triggers.empty? && shadow_tables.empty?

    raise LeftoversPresent, failure_message(leftover_triggers, shadow_tables)
  end

  private
    attr_reader :table, :connection

    # The trigger names pt-osc would try to create for this table. Looked up by exact
    # name rather than by a LIKE pattern: a pattern would also match triggers for a
    # table whose name merely starts with ours (`purchases` vs `purchase_refunds`),
    # and blocking a migration because of an unrelated table's leftovers would be its
    # own outage.
    def find_leftover_triggers
      expected = TRIGGER_SUFFIXES.map { |suffix| "pt_osc_#{database}_#{table}_#{suffix}" }

      connection.select_values(<<~SQL.squish)
        SELECT TRIGGER_NAME FROM information_schema.triggers
        WHERE TRIGGER_SCHEMA = #{connection.quote(database)}
          AND TRIGGER_NAME IN (#{expected.map { connection.quote(it) }.join(', ')})
        ORDER BY TRIGGER_NAME
      SQL
    end

    # pt-osc's shadow table is `_<table>_new`. It prepends another underscore for each
    # name already taken, so an abandoned run leaves `_purchases_new` behind and the
    # next run works on `__purchases_new` — meaning several generations of leftovers
    # can pile up. Match the whole family so the message accounts for all of them, and
    # anchor the pattern on the exact table name so a longer table name cannot match.
    def find_shadow_tables
      connection.select_values(<<~SQL.squish)
        SELECT TABLE_NAME FROM information_schema.tables
        WHERE TABLE_SCHEMA = #{connection.quote(database)}
          AND TABLE_NAME REGEXP #{connection.quote("^_+#{Regexp.escape(table)}_new$")}
        ORDER BY LENGTH(TABLE_NAME), TABLE_NAME
      SQL
    end

    def database
      @database ||= connection.current_database
    end

    def failure_message(leftover_triggers, shadow_tables)
      message = +"[PtOscLeftoverCheck] Refusing to run an online schema change on `#{table}`: " \
                 "an earlier pt-online-schema-change on this table was abandoned without cleanup.\n\n"

      if leftover_triggers.any?
        message << "Leftover triggers (these are the reason pt-osc would fail, with " \
                   "\"Trigger already exists\"):\n"
        leftover_triggers.each { message << "  - #{it}\n" }
        message << "\n"
      end

      if shadow_tables.any?
        message << "Leftover shadow table(s):\n"
        shadow_tables.each { message << "  - #{database}.#{it}\n" }
        message << "\n"
      end

      message << <<~TEXT
        Nothing has been changed. While these exist, every schema change to `#{table}` fails
        the same way, including an out-of-band pt-osc run.

        Clearing them is a destructive operation on a live table and is deliberately not
        automated: the triggers are mirroring writes right now, so they must be dropped
        BEFORE the shadow table (dropping the table first leaves triggers writing to a table
        that no longer exists, which fails every write to `#{table}`). Do it off-peak, per
        table, and confirm the shadow table is not part of a schema change somebody is
        actually still running.

        Background and a worked example: gumroad-private#1417.
      TEXT

      message
    end
end
