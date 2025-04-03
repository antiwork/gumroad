# frozen_string_literal: true

class RemoveInfos < ActiveRecord::Migration
  def up
    drop_table :infos
  end

  def down
    create_table :infos do |t|
      t.string :filetype
      t.string :filegroup
      t.integer :size
      t.integer :duration
      t.integer :bitrate
      t.integer :framerate
      t.integer :width
      t.integer :height
      t.integer :pagelength
    end
  end
end
