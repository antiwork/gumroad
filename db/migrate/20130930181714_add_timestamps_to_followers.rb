# frozen_string_literal: true

class AddTimestampsToFollowers < ActiveRecord::Migration[4.2]
  def change
    change_table :followers do |t|
      t.timestamps
    end
  end
end
