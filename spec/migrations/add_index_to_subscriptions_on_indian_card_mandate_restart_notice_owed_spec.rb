# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261216160004_add_index_to_subscriptions_on_indian_card_mandate_restart_notice_owed").to_s

# Reads the live connection's metadata and the checked-in schema; it never runs DDL against the shared test database.
describe AddIndexToSubscriptionsOnIndianCardMandateRestartNoticeOwed do
  let(:index_name) { described_class::INDEX_NAME }
  let(:columns) { %w[indian_card_mandate_restart_notice_owed indian_card_mandate_restart_notice_recorded_at] }

  it "runs outside a DDL transaction" do
    expect(described_class.disable_ddl_transaction).to be(true)
  end

  it "names the index within MySQL's identifier limit" do
    expect(index_name.length).to be <= 64
  end

  it "declares the owed flag followed by its recorded time" do
    expect(described_class::COLUMNS.map(&:to_s)).to eq(columns)
  end

  it "indexes the owed flag and its recorded time together, non-uniquely, so the sweep can split fresh from stale" do
    index = ActiveRecord::Base.connection.indexes(:subscriptions).find { _1.name == index_name }

    expect(index).to be_present
    expect(index.columns).to eq(columns)
    expect(index.unique).to be(false)
  end

  it "does not leave a single-column index on the owed flag behind" do
    expect(ActiveRecord::Base.connection.indexes(:subscriptions).map(&:columns)).not_to include([columns.first])
  end

  it "is recorded in the checked-in schema with the same shape" do
    schema = Rails.root.join("db/schema.rb").read

    expect(schema).to include(%(t.index #{columns.inspect}, name: "#{index_name}"))
    expect(schema).not_to include(%(t.index #{columns.first(1).inspect}))
    expect(schema).not_to match(/t\.index #{Regexp.escape(columns.inspect)}, name: "#{index_name}", unique: true/)
  end
end
