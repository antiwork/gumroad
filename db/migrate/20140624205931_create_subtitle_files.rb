# frozen_string_literal: true

class CreateSubtitleFiles < ActiveRecord::Migration
  def change
    create_table :subtitle_files do |t|
      t.string :url
      t.string :language

      t.timestamps
    end
  end
end
