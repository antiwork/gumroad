# frozen_string_literal: true

class ChangeTerritoryRestrictionToText < ActiveRecord::Migration[4.2]
  def up
    change_column :links, :territory_restriction, :text
  end

  def down
    change_column :links, :territory_restriction, :string
  end
end
