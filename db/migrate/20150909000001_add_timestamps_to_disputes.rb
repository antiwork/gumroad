# frozen_string_literal: true

class AddTimestampsToDisputes < ActiveRecord::Migration
  def change
    add_column :disputes, :created_at, :datetime
    add_column :disputes, :updated_at, :datetime
  end
end
