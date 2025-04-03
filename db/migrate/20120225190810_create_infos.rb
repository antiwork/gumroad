# frozen_string_literal: true

class CreateInfos < ActiveRecord::Migration
  def change
    create_table :infos do |t|
      t.string :type
      t.integer :size
      t.integer :duration
      t.integer :bitrate
      t.integer :framerate
      t.string :resolution
      t.integer :pagelength

      t.timestamps
    end
  end
end
