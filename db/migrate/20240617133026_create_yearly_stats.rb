# frozen_string_literal: true

class CreateYearlyStats < ActiveRecord::Migration[7.1]
  def change
    create_table :yearly_stats do |t|
      t.bigint :user_id, null: false, index: { unique: true }
      t.json :analytics_data, null: false

      t.timestamps
    end
  end
end
