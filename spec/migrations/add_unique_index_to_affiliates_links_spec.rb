# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261207160000_add_unique_index_to_affiliates_links").to_s

describe AddUniqueIndexToAffiliatesLinks do
  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    original_index = connection.indexes(:affiliates_links).find { _1.name == described_class::INDEX_NAME.to_s }
    example.run
  ensure
    connection.remove_index(:affiliates_links, name: described_class::INDEX_NAME) if connection.index_name_exists?(:affiliates_links, described_class::INDEX_NAME)
    if original_index
      connection.add_index(
        :affiliates_links,
        original_index.columns,
        unique: original_index.unique,
        name: original_index.name
      )
    end
  end

  it "leaves the required unique index in place" do
    expect { migration.up }.not_to change { connection.indexes(:affiliates_links).map(&:name) }
  end

  it "fails closed when the index name belongs to a non-unique index" do
    connection.remove_index(:affiliates_links, name: described_class::INDEX_NAME)
    connection.add_index(:affiliates_links, described_class::COLUMNS, name: described_class::INDEX_NAME)

    expect { migration.up }.to raise_error(RuntimeError, /does not match the required unique composite index/)
    index = connection.indexes(:affiliates_links).find { _1.name == described_class::INDEX_NAME.to_s }
    expect(index.unique).to be(false)
  end
end
