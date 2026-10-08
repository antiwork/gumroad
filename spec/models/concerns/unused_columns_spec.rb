# frozen_string_literal: true

require "spec_helper"

describe UnusedColumns do
  class TestModel < ActiveRecord::Base
    include UnusedColumns

    unused_columns :description
  end

  # A temporary table exists only on the connection that created it, so it is made
  # on each example's connection: the suite can hand an example a different one
  # than the connection that loaded this file.
  # The explicit drop keeps TEMPORARY in the SQL, which `force: true` leaves out: MySQL
  # commits the example's transaction before a plain DROP TABLE.
  before do
    ActiveRecord::Base.connection.drop_table :test_models, temporary: true, if_exists: true
    ActiveRecord::Base.connection.create_table :test_models, temporary: true do |t|
      t.string :name
      t.string :email
      t.string :description
    end
    TestModel.reset_column_information
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
