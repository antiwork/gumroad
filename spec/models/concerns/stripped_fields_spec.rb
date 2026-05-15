# frozen_string_literal: true

require "spec_helper"

describe StrippedFields do
  # Use a non-temporary table to avoid connection-scoped lifetime issues.
  # Temporary tables are lost when the DB connection is recycled, which can
  # happen between file load time and test execution in parallel CI.
  before(:all) do
    ActiveRecord::Schema.define do
      create_table :stripped_fields_test, force: true do |t|
        t.string :name
        t.string :email
        t.string :description
        t.string :sql
        t.string :code
      end
    end
  end

  after(:all) do
    ActiveRecord::Schema.define do
      drop_table :stripped_fields_test, if_exists: true
    end
  end

  let(:test_model) do
    Class.new(ApplicationRecord) do
      self.table_name = "stripped_fields_test"

      include StrippedFields

      stripped_fields :name, :email, transform: ->(v) { v&.upcase }
      stripped_fields :description, nilify_blanks: false
      stripped_fields :sql, remove_duplicate_spaces: false
      stripped_fields :code, transform: ->(v) { v&.gsub(/\s/, "") }
    end
  end

  let(:record) do
    test_model.new(
      name: "  my   name ",
      email: "   ",
      description: " ",
      sql: "  keep  extra  spaces   ",
      code: " 1234 56\n78 "
    )
  end

  it "applies transform and default blank nilification" do
    record.validate

    expect(record.name).to eq("MY NAME")
    expect(record.email).to be_nil
  end

  it "keeps blank strings when nilify_blanks is false" do
    record.validate

    expect(record.description).to eq("")
  end

  it "preserves duplicate spaces when remove_duplicate_spaces is false" do
    record.validate

    expect(record.sql).to eq("keep  extra  spaces")
  end

  it "applies custom transform for code" do
    record.validate

    expect(record.code).to eq("12345678")
  end
end
