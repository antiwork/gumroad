# frozen_string_literal: true

class ChangeVersionsIdType < ActiveRecord::Migration[5.2]
  def up
    safety_assured do
      change_column :versions, :id, :bigint, null: false, unique: true, auto_increment: true
    end
  end

  def down
    safety_assured do
      change_column :versions, :id, :int, null: false, unique: true, auto_increment: true
    end
  end
end
