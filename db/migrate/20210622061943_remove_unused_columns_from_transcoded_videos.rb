# frozen_string_literal: true

class RemoveUnusedColumnsFromTranscodedVideos < ActiveRecord::Migration[6.1]
  def up
    change_table :transcoded_videos, bulk: true do |t|
      t.remove :transcoder_preset_key
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :link_id, :bigint
      t.change :product_file_id, :bigint
    end
  end

  def down
    change_table :transcoded_videos, bulk: true do |t|
      t.string :transcoder_preset_key
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :link_id, :integer
      t.change :product_file_id, :integer
    end
  end
end
