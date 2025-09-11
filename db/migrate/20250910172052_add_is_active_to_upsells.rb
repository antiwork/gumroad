# frozen_string_literal: true

class AddIsActiveToUpsells < ActiveRecord::Migration[7.1]
  def change
    add_column :upsells, :is_active, :boolean, default: true, null: false
  end
end
