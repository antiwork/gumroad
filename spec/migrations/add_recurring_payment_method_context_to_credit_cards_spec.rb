# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261206235900_add_recurring_payment_method_context_to_credit_cards").to_s

describe AddRecurringPaymentMethodContextToCreditCards do
  subject(:migration) { described_class.new }

  let(:connection) { double }

  before do
    allow(migration).to receive(:connection).and_return(connection)
    allow(migration).to receive(:column_exists?).and_return(true)
  end

  described_class::SUPERSEDED_VERSIONS.each do |version|
    it "preserves the columns when superseded version #{version} is recorded" do
      allow(connection).to receive(:select_value) { |sql| sql.include?(version) ? 1 : nil }
      expect(migration).not_to receive(:change_table)

      migration.down
    end
  end

  it "removes the columns when no superseded version is recorded" do
    table = double
    allow(connection).to receive(:select_value).and_return(nil)
    expect(migration).to receive(:change_table).with(:credit_cards, bulk: true).and_yield(table)
    described_class::COLUMNS.each_key { |name| expect(table).to receive(:remove).with(name) }

    migration.down
  end
end
