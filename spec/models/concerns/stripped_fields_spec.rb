# frozen_string_literal: true

require "spec_helper"

ActiveRecord::Schema.define do
  create_table :test_fields, temporary: true, force: true do |t|
    t.string :name
    t.string :email
    t.string :description
    t.string :sql
    t.string :code
  end
end

describe StrippedFields do
  class TestField < ApplicationRecord
    include StrippedFields

    stripped_fields :name, :email, transform: ->(v) { v.upcase }
    stripped_fields :description, nilify_blanks: false
    stripped_fields :sql, remove_duplicate_spaces: false
    stripped_fields :code, transform: ->(v) { v.gsub(/\s/, "") }
  end

  let(:record) do
    TestField.new(
      name: "  my   name ",
      email: "   ",
      description: " ",
      sql: "  keep  extra  spaces   ",
      code: " 1234 56\n78 "
    )
  end

  it "updates values" do
    record.validate

    expect(record.name).to eq("MY NAME")
    expect(record.email).to be_nil
    expect(record.description).to eq("")
    expect(record.sql).to eq("keep  extra  spaces")
    expect(record.code).to eq("12345678")
  end
end
