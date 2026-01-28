# frozen_string_literal: true

class AddTerritoryRestrictionToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :territory_restriction, :string
  end
end
