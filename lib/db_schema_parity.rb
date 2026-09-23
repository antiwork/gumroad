# frozen_string_literal: true

# Compares the schema db/schema.rb declares with the schema the live database actually has.
#
# Rails records a migration's version as applied the moment `up` returns, so a DDL statement that
# never took effect leaves nothing for a later deploy to notice and the code that reads through the
# missing index or column keeps working. Only "declared by db/schema.rb, missing live" is reported:
# production legitimately carries schema objects schema.rb does not know about, and a rolling deploy
# can be mid-migration.
#
# Both sides are parsed in Rails' own schema dump format, so a parser quirk cancels out instead of
# surfacing as drift.
class DbSchemaParity
  class DriftError < StandardError; end

  # `create_table "charges", charset: ... do |t|`
  CREATE_TABLE = /\A\s*create_table "([^"]+)"/
  # `t.index ["a", "b"], name: "index_charges_on_a_and_b", unique: true`
  INDEX = /\A\s*t\.index .*name: "([^"]+)"/
  # `t.bigint "seller_id", null: false`
  COLUMN = /\A\s*t\.[a-z_]+ "([^"]+)"/

  Missing = Struct.new(:table, :kind, :name, keyword_init: true) do
    def to_s = "#{table}: #{kind} #{name}"
  end

  def self.from_live_connection(pool = ActiveRecord::Base.connection_pool)
    dump = StringIO.new
    ActiveRecord::SchemaDumper.dump(pool, dump)
    new(declared: File.read(Rails.root.join("db/schema.rb")), live: dump.string)
  end

  def initialize(declared:, live:)
    @declared = parse(declared)
    @live = parse(live)
  end

  # Sorted for a stable report: this ends up in a Sentry message and in deploy logs.
  def missing
    rows = []
    @declared.each do |table, shape|
      unless @live.key?(table)
        rows << Missing.new(table:, kind: "table", name: table)
        next
      end
      %i[indexes columns].each do |kind|
        (shape[kind] - @live[table][kind]).sort.each do |name|
          rows << Missing.new(table:, kind: kind.to_s.singularize, name:)
        end
      end
    end
    rows
  end

  private
    def parse(dump)
      table = nil
      dump.each_line.each_with_object({}) do |line, acc|
        if (match = CREATE_TABLE.match(line))
          table = match[1]
          acc[table] ||= { indexes: [], columns: [] }
          next
        end
        next if table.nil?

        if (match = INDEX.match(line))
          acc[table][:indexes] << match[1]
        elsif (match = COLUMN.match(line))
          acc[table][:columns] << match[1]
        end
      end
    end
end
