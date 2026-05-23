# frozen_string_literal: true

require "test_helper"

class UnusedColumnsTest < ActiveSupport::TestCase
  self.described_class = UnusedColumns



  ActiveRecord::Schema.define do
    create_table :test_models, temporary: true, force: true do |t|
      t.string :name
      t.string :email
      t.string :description
    end
  end

  context_ UnusedColumns do
    class TestModel < ActiveRecord::Base
      include UnusedColumns

      unused_columns :description
    end

    let(:record) do
      TestModel.new
    end

  test "raises NoMethodError when reading a value from an unused column" do
      expect { record.description }.to raise_error(
        NoMethodError
      ).with_message("Column description is deprecated and no longer used.")
    end

  test "raises NoMethodError when assigning a value to a unused column" do
      expect { record.description = "some value" }.to raise_error(
        NoMethodError
      ).with_message("Column description is deprecated and no longer used.")
    end

  test "returns unused attributes" do
      expect(TestModel.unused_attributes).to eq(["description"])
    end
  end
end
