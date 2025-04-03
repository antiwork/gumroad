# frozen_string_literal: true

class RemoveShownOnProfileFromProducts < ActiveRecord::Migration[7.0]
  def up
    remove_column :links, :shown_on_profile
  end

  def down
    change_table :links, bulk: true do |t|
      t.column :shown_on_profile, :boolean, default: true
      t.index :shown_on_profile
    end
  end
end
