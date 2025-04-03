# frozen_string_literal: true

class AddFractionalSecondsToPapertrailCreatedAt < ActiveRecord::Migration[7.1]
  def up
    change_column :versions, :created_at, :datetime, limit: 6
  end

  def down
    change_column :versions, :created_at, :datetime, precision: nil
  end
end
