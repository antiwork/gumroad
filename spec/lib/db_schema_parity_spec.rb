# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/db_schema_parity"

describe DbSchemaParity do
  # Both sides are Rails schema dumps, so the fixtures are written the way the dumper writes them.
  def dump(indexes: [], columns: [], table: "charges")
    <<~RUBY
      ActiveRecord::Schema[8.1].define(version: 2026_12_16_090003) do
        create_table "#{table}", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
          #{columns.map { |column| %(t.bigint "#{column}", null: false) }.join("\n  ")}
          #{indexes.map { |index| %(t.index ["x"], name: "#{index}", unique: true) }.join("\n  ")}
        end
      end
    RUBY
  end

  def parity(declared_indexes: [], live_indexes: [], declared_columns: [], live_columns: [])
    described_class.new(
      declared: dump(indexes: declared_indexes, columns: declared_columns),
      live: dump(indexes: live_indexes, columns: live_columns),
    )
  end

  it "reports nothing when the live schema has everything schema.rb declares" do
    expect(parity(declared_indexes: %w[one], live_indexes: %w[one], declared_columns: %w[a], live_columns: %w[a]).missing).to eq([])
  end

  it "reports an index schema.rb declares and the live database does not have" do
    missing = parity(declared_indexes: %w[index_charges_on_stripe_payment_intent_id], live_indexes: []).missing

    expect(missing.map(&:to_s)).to eq(["charges: index index_charges_on_stripe_payment_intent_id"])
  end

  it "reports a column schema.rb declares and the live database does not have" do
    missing = parity(declared_columns: %w[stripe_payment_intent_id], live_columns: []).missing

    expect(missing.map(&:to_s)).to eq(["charges: column stripe_payment_intent_id"])
  end

  it "does not report an index or column the live database has and schema.rb does not" do
    # Production carries indexes built out of band, and a rolling deploy can be mid-migration.
    expect(parity(declared_indexes: [], live_indexes: %w[out_of_band], declared_columns: [], live_columns: %w[extra]).missing).to eq([])
  end

  it "reports a table schema.rb declares and the live database does not have" do
    missing = described_class.new(declared: dump, live: dump(table: "unrelated")).missing

    expect(missing.map(&:to_s)).to eq(["charges: table charges"])
  end

  it "parses the real db/schema.rb" do
    schema = File.read(Rails.root.join("db/schema.rb"))
    # Same file on both sides, minus its index lines: every index it declares must be reported.
    live = schema.lines.reject { |line| line.include?("t.index") }.join

    expect(described_class.new(declared: schema, live:).missing.map(&:name)).to include("index_charges_on_stripe_payment_intent_id")
  end
end
