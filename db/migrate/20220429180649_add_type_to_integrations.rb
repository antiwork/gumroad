# frozen_string_literal: true

class AddTypeToIntegrations < ActiveRecord::Migration[6.1]
  def change
    add_column :integrations, :type, :string
  end
end
