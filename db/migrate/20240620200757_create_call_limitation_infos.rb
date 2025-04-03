# frozen_string_literal: true

class CreateCallLimitationInfos < ActiveRecord::Migration[7.1]
  def change
    create_table :call_limitation_infos do |t|
      t.references :call, null: false
      t.integer :minimum_notice_in_minutes
      t.integer :maximum_calls_per_day

      t.timestamps
    end
  end
end
