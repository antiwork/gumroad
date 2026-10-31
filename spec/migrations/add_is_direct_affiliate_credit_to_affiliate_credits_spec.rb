# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261223000002_add_is_direct_affiliate_credit_to_affiliate_credits").to_s

describe AddIsDirectAffiliateCreditToAffiliateCredits do
  subject(:migration) { described_class.new }

  let(:connection) { double }

  before do
    allow(migration).to receive(:connection).and_return(connection)
  end

  it "adds the column when it is missing" do
    allow(migration).to receive(:column_exists?).and_return(false)
    expect(migration).to receive(:add_column).with(:affiliate_credits, :is_direct_affiliate_credit, :boolean, default: false, null: false)

    migration.up
  end

  it "skips the column a database that ran the superseded version already has" do
    allow(migration).to receive(:column_exists?).and_return(true)
    expect(migration).not_to receive(:add_column)

    migration.up
  end

  it "preserves the column on rollback while the superseded version is recorded" do
    allow(migration).to receive(:column_exists?).and_return(true)
    allow(connection).to receive(:select_value) { |sql| sql.include?(described_class::SUPERSEDED_VERSION) ? 1 : nil }
    expect(migration).not_to receive(:remove_column)

    migration.down
  end

  it "removes the column on rollback when no superseded version is recorded" do
    allow(migration).to receive(:column_exists?).and_return(true)
    allow(connection).to receive(:select_value).and_return(nil)
    expect(migration).to receive(:remove_column).with(:affiliate_credits, :is_direct_affiliate_credit)

    migration.down
  end
end
