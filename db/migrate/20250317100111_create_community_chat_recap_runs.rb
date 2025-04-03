# frozen_string_literal: true

class CreateCommunityChatRecapRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :community_chat_recap_runs do |t|
      t.string :recap_frequency, null: false, index: true
      t.datetime :from_date, null: false
      t.datetime :to_date, null: false
      t.integer :recaps_count, null: false, default: 0
      t.datetime :finished_at
      t.datetime :notified_at
      t.timestamps

      t.index %i[recap_frequency from_date to_date], unique: true
    end
  end
end
