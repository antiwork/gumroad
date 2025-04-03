# frozen_string_literal: true

class RemoveContentLengthUnitRequiredFromMediaLocation < ActiveRecord::Migration[6.1]
  def up
    change_table :media_locations, bulk: true do |t|
      t.change :content_length, :integer, null: true
      t.change :unit, :string, null: true
    end
  end

  def down
    change_table :media_locations, bulk: true do |t|
      t.change :content_length, :integer, null: false
      t.change :unit, :string, null: false
    end
  end
end
