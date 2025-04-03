# frozen_string_literal: true

class CreateCalls < ActiveRecord::Migration[7.1]
  def change
    create_table :calls do |t|
      t.references :purchase
      t.string :call_url, limit: 1024
      t.datetime :start_time
      t.datetime :end_time

      t.timestamps
    end
  end
end
