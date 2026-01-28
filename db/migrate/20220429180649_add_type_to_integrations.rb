# frozen_string_literal: true

class AddTypeToIntegrations < ActiveRecord::Migration[4.2]
  def change
    add_column :integrations, :type, :string
  end
end
