# frozen_string_literal: true

require "spec_helper"

ActiveRecord::Schema.define do
  create_table :test_models, temporary: true, force: true do |t|
    t.string :name
    t.string :email
    t.string :description
  end
end

describe UnusedColumns do
  class TestModel < ActiveRecord::Base
    include UnusedColumns

    unused_columns :description
  end

  let(:record) do
    TestModel.new
  end

  it "raises NoMethodError when reading a value from an unused column" do
    expect { record.description }.to raise_error(
      NoMethodError
    ).with_message("Column description is deprecated and no longer used.")
  end

  it "raises NoMethodError when assigning a value to a unused column" do
    expect { record.description = "some value" }.to raise_error(
      NoMethodError
    ).with_message("Column description is deprecated and no longer used.")
  end

  it "returns unused attributes" do
    expect(TestModel.unused_attributes).to eq(["description"])
  end
end
