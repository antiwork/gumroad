# frozen_string_literal: true

class IncreaseUsersFlagsToBigint < ActiveRecord::Migration[4.2]
  def up
    change_column :users, :flags, :bigint, default: 1, null: false
  end

  def down
    change_column :users, :flags, :int, default: 1, null: false
  end
end
