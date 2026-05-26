# frozen_string_literal: true

class CreateWalksFreeTrials < ActiveRecord::Migration[7.1]
  def change
    create_table :walks_free_trials do |t|
      t.references :walks_app_attest_key, null: false, foreign_key: false, index: { unique: true }
      t.datetime :consumed_at, null: false, precision: 6
      t.timestamps precision: 6
    end
  end
end
