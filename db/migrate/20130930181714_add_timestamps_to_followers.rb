# frozen_string_literal: true

class AddTimestampsToFollowers < ActiveRecord::Migration
  def change
    change_table :followers do |t|
      t.timestamps
    end
  end
end
