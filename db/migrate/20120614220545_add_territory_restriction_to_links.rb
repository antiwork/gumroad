# frozen_string_literal: true

class AddTerritoryRestrictionToLinks < ActiveRecord::Migration
  def change
    add_column :links, :territory_restriction, :string
  end
end
