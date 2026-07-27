# frozen_string_literal: true

# Detects leftover pt-online-schema-change artifacts, so a migration is never run
# against a table that still carries them.
#
# Background. Schema changes go through Alterity, which shells out to
# pt-online-schema-change (see config/initializers/alterity.rb). pt-osc works by
# creating a shadow copy of the table (`_<table>_new`), installing three triggers
# on the original that mirror every write into the copy, backfilling the existing
# rows, and finally swapping the two tables and dropping the triggers.
#
# The trigger names it uses are derived from the database and table names with
# nothing to make them unique per run: `pt_osc_<db>_<table>_ins`, `_upd`, `_del`.
# So if a pt-osc run is abandoned without cleaning up -- killed halfway, or its
# deploy cancelled -- the leftover triggers make EVERY later schema change to that
# table fail, because pt-osc cannot create triggers that already exist. It fails
# within seconds, drops its own scratch table, and leaves nothing behind in the
# database to explain why.
#
# That is not hypothetical. Two abandoned runs sat on `purchases` and `users` for
# months, and the second thing they broke was the deploy pipeline: the failure
# hung the deploy rather than failing it, the pipeline got unblocked by marking the
# migration applied by hand, and `schema_migrations` was left claiming an index
# that had never been built (antiwork/gumroad-private#1417).
#
# The leftovers are also expensive while they sit there: the triggers keep firing,
# so every INSERT, UPDATE and DELETE on the real table is written twice, and the
# shadow table keeps growing. On `purchases` and `users` that was about 60 GB per
# server -- on the writer and on every replica -- and a duplicated write on the two
# busiest tables in the product.
#
# So this check exists to make the leftovers loud at the only moment anybody is
# looking: the start of the migration phase of a deploy.
class PtOscLeftovers
  # pt-osc names its triggers `pt_osc_<db>_<table>_<event>`, where <event> is one
  # of ins/upd/del. The prefix alone is not specific enough to identify a leftover:
  # anything a person names `pt_osc_...` would match. Both halves are checked, and
  # the trigger is only attributed to a table when its own EVENT_OBJECT_TABLE
  # appears in the middle -- which is also the only reliable way to recover the
  # table, since table names contain underscores and the name is not safely
  # splittable.
  #
  # `\\_` escapes the underscores for LIKE, where a bare `_` is a wildcard.
  TRIGGER_NAME_PATTERN = "pt\\_osc\\_%"
  TRIGGER_EVENTS = %w[ins upd del].freeze

  # `_<table>_new` -- pt-osc's shadow table. The leading underscore is what
  # distinguishes it from an application table; `\\_` escapes it for LIKE.
  SHADOW_TABLE_NAME_PATTERN = "\\_%\\_new"

  Leftover = Struct.new(:table, :triggers, :shadow_tables, keyword_init: true) do
    def description
      parts = []
      parts << "triggers #{triggers.sort.join(', ')}" if triggers.any?
      parts << "shadow table#{'s' if shadow_tables.size > 1} #{shadow_tables.sort.join(', ')}" if shadow_tables.any?
      "#{table}: #{parts.join('; ')}"
    end
  end

  class << self
    # Every table that still carries pt-osc artifacts, as Leftover structs.
    #
    # A table is reported when it has leftover triggers, a leftover shadow table,
    # or both. Both halves matter on their own: the triggers are what break the
    # next schema change, and a shadow table without triggers is still tens of
    # gigabytes of storage nobody reads.
    def all(connection: ActiveRecord::Base.connection)
      by_table = {}

      trigger_leftovers(connection).each do |table, trigger|
        entry = (by_table[table] ||= { triggers: [], shadow_tables: [] })
        entry[:triggers] << trigger
      end

      shadow_table_leftovers(connection).each do |table, shadow_table|
        entry = (by_table[table] ||= { triggers: [], shadow_tables: [] })
        entry[:shadow_tables] << shadow_table
      end

      by_table.map do |table, entry|
        Leftover.new(table:, triggers: entry[:triggers], shadow_tables: entry[:shadow_tables])
      end.sort_by(&:table)
    end

    # Whether a specific table can safely take a schema change right now.
    def leftovers_for(table, connection: ActiveRecord::Base.connection)
      all(connection:).find { |leftover| leftover.table == table.to_s }
    end

    # Whether these leftovers will actually break the migration about to run.
    #
    # Only leftover TRIGGERS block. pt-osc fails because it cannot create triggers
    # that already exist -- not because of the shadow table, which it simply renames
    # around: Ershad's reproduction on antiwork/gumroad-private#1417 shows it creating
    # `__purchases_new` and altering it successfully with `_purchases_new` already
    # present, then failing at "Creating triggers...".
    #
    # So a shadow table on its own is dead storage worth reporting, not a reason to
    # refuse a deploy that would have worked.
    def blocking?(leftovers)
      leftovers.any? { |leftover| leftover.triggers.any? }
    end

    # The operator-facing explanation. Kept next to the detection so the message a
    # deploy prints and the message a console prints cannot drift apart.
    #
    # The two kinds of leftover are explained separately, because they are
    # different problems with different cleanup steps. Telling somebody to drop
    # triggers on a table that has none sends them looking for something that is
    # not there instead of at the shadow table that is.
    def failure_message(leftovers)
      with_triggers = leftovers.select { |leftover| leftover.triggers.any? }
      shadow_only = leftovers.reject { |leftover| leftover.triggers.any? }

      paragraphs = [
        "#{blocking?(leftovers) ? 'Refusing to migrate' : 'Found'}: #{leftovers.size} table#{'s' if leftovers.size > 1} still #{leftovers.size > 1 ? 'carry' : 'carries'} pt-online-schema-change artifacts from a run that never cleaned up.",
        leftovers.map { |leftover| "  - #{leftover.description}" }.join("\n"),
      ]

      if with_triggers.any?
        paragraphs << "Any schema change to #{table_list(with_triggers)} will fail, because pt-online-schema-change cannot create triggers that already exist -- and those leftover triggers are duplicating every write to the table in the meantime."
      end

      if shadow_only.any?
        paragraphs << "#{table_list(shadow_only)} #{shadow_only.size > 1 ? 'carry' : 'carries'} a leftover shadow table but no leftover triggers, so writes are not being duplicated there and schema changes are not blocked: pt-online-schema-change picks the next free name (`__<table>_new`) when its usual one is taken. What is left is storage on the writer and on every replica that nothing reads, from a run that copied rows and then died. Worth confirming no run is still in flight before dropping it."
      end

      paragraphs << cleanup_instruction(with_triggers:, shadow_only:)

      paragraphs << "Do NOT work around this by inserting the migration's version into schema_migrations by hand. That leaves the schema claiming a change that does not exist, which is how antiwork/gumroad-private#1417 happened."

      paragraphs << "If you are deliberately deploying while a pt-osc run is genuinely in flight, set ALLOW_PT_OSC_LEFTOVERS=1 for that deploy."

      paragraphs.join("\n\n").strip
    end

    private
      def table_list(leftovers)
        leftovers.map(&:table).sort.join(", ")
      end

      # What to actually do about it, which depends on which artifacts are there.
      def cleanup_instruction(with_triggers:, shadow_only:)
        shadow_warning = "Dropping a large shadow table unlinks a multi-gigabyte file and can briefly lag the replicas."

        if with_triggers.any? && shadow_only.any?
          "Clean the artifacts up before deploying this migration, one table at a time and off-peak: where a table has both, drop its triggers FIRST and then its shadow table; where it has only a shadow table, drop that. #{shadow_warning}"
        elsif with_triggers.any?
          "Clean the artifacts up before deploying this migration: drop the triggers FIRST, then the shadow table, one table at a time and off-peak. #{shadow_warning}"
        else
          "Drop the leftover shadow table#{'s' if shadow_only.size > 1} when convenient, one table at a time and off-peak -- this does not block the migration. #{shadow_warning}"
        end
      end

      # [[altered_table, trigger_name], ...] for every pt-osc trigger in this
      # database. The altered table is the trigger's own EVENT_OBJECT_TABLE rather
      # than something parsed out of the trigger name -- table names can contain
      # underscores, so the name is not safely splittable.
      def trigger_leftovers(connection)
        rows = connection.select_rows(<<~SQL.squish)
          SELECT event_object_table, trigger_name
          FROM information_schema.triggers
          WHERE trigger_schema = DATABASE()
            AND trigger_name LIKE '#{TRIGGER_NAME_PATTERN}'
        SQL

        rows.filter_map do |table, trigger|
          table = table.to_s
          trigger = trigger.to_s
          next unless pt_osc_trigger_name?(trigger, table)

          [table, trigger]
        end
      end

      # Whether a trigger name is one pt-osc would have generated for this table:
      # `pt_osc_<something>_<table>_<event>`. The database name in the middle is not
      # pinned, because a leftover can predate a database rename and pinning it would
      # silently stop recognising exactly the artifacts this exists to catch.
      def pt_osc_trigger_name?(trigger, table)
        TRIGGER_EVENTS.any? do |event|
          trigger.start_with?("pt_osc_") && trigger.end_with?("_#{table}_#{event}")
        end
      end

      # [[altered_table, shadow_table_name], ...] for every pt-osc shadow table
      # whose original still exists.
      #
      # The original has to still exist for this to be a leftover worth reporting:
      # `_foo_new` with no `foo` is not an interrupted schema change on a live
      # table, and refusing to deploy over it would be a false alarm nobody can
      # clear by fixing the thing being complained about.
      def shadow_table_leftovers(connection)
        names = connection.select_values(<<~SQL.squish)
          SELECT table_name
          FROM information_schema.tables
          WHERE table_schema = DATABASE()
            AND table_name LIKE '#{SHADOW_TABLE_NAME_PATTERN}'
        SQL

        existing = connection.select_values(<<~SQL.squish).map(&:to_s).to_set
          SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()
        SQL

        names.filter_map do |shadow_table|
          # `_purchases_new` -> `purchases`
          original = shadow_table.to_s.delete_prefix("_").delete_suffix("_new")
          next if original.blank?
          next unless existing.include?(original)

          [original, shadow_table.to_s]
        end
      end
  end
end
