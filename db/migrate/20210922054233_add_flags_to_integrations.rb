# frozen_string_literal: true

class AddFlagsToIntegrations < ActiveRecord::Migration[4.2]
  def change
    add_column :integrations, :flags, :bigint, default: 0, null: false
  end
end
