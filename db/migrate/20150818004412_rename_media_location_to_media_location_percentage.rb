# frozen_string_literal: true

class RenameMediaLocationToMediaLocationPercentage < ActiveRecord::Migration
  def up
    rename_column :consumption_events, :media_location, :media_location_basis_points
  end

  def down
    rename_column :consumption_events, :media_location_basis_points, :media_location
  end
end
