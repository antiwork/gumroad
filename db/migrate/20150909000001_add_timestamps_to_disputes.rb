# frozen_string_literal: true

class AddTimestampsToDisputes < ActiveRecord::Migration[4.2]
  def change
    add_column :disputes, :created_at, :datetime
    add_column :disputes, :updated_at, :datetime
  end
end
