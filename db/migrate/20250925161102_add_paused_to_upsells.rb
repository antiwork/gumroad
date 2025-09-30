# frozen_string_literal: true

class AddPausedToUpsells < ActiveRecord::Migration[7.1]
  def change
    add_column :upsells, :paused, :boolean, default: false, null: false
  end
end
