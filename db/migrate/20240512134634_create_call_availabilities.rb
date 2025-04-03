# frozen_string_literal: true

class CreateCallAvailabilities < ActiveRecord::Migration[7.1]
  def change
    create_table :call_availabilities do |t|
      t.references :call, null: false
      t.datetime :start_time
      t.datetime :end_time
      t.timestamps
    end
  end
end
