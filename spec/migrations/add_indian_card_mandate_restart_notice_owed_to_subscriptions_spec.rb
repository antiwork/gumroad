# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261216160003_add_indian_card_mandate_restart_notice_owed_to_subscriptions").to_s

# Reads the live connection's metadata and the checked-in schema; it never runs DDL against the shared test database.
describe AddIndianCardMandateRestartNoticeOwedToSubscriptions do
  let(:column_name) { "indian_card_mandate_restart_notice_owed" }
  let(:recorded_at_column_name) { "indian_card_mandate_restart_notice_recorded_at" }
  let(:schema) { Rails.root.join("db/schema.rb").read }

  def column(name)
    ActiveRecord::Base.connection.columns(:subscriptions).find { _1.name == name }
  end

  it "adds a boolean column that defaults to false and rejects null" do
    owed = column(column_name)

    expect(owed.type).to eq(:boolean)
    expect(owed.default).to be(false)
    expect(owed.null).to be(false)
  end

  it "adds a nullable datetime for when the first notice was recorded" do
    recorded_at = column(recorded_at_column_name)

    expect(recorded_at.type).to eq(:datetime)
    expect(recorded_at.null).to be(true)
    expect(recorded_at.default).to be_nil
  end

  it "is recorded in the checked-in schema with the same definitions" do
    expect(schema).to include(%(t.boolean "#{column_name}", default: false, null: false))
    expect(schema).to include(%(t.datetime "#{recorded_at_column_name}"\n))
  end

  it "adds only the columns, leaving the index to its own migration" do
    source = Rails.root.join("db/migrate/20261216160003_add_indian_card_mandate_restart_notice_owed_to_subscriptions.rb").read

    expect(source).not_to include("add_index")
    expect(source).not_to include("t.index")
  end

  it "leaves a new subscription with no notice owed and no recorded time" do
    expect(Subscription.new.indian_card_mandate_restart_notice_owed).to be(false)
    expect(Subscription.new.indian_card_mandate_restart_notice_recorded_at).to be_nil
  end
end
