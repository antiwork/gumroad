# frozen_string_literal: true

class AddFlagsToUpsells < ActiveRecord::Migration[4.2]
  def change
    change_table :upsells, bulk: true do |t|
      t.integer :flags, default: 0, null: false
    end
  end
end
