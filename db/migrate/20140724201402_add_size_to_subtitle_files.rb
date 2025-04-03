# frozen_string_literal: true

class AddSizeToSubtitleFiles < ActiveRecord::Migration
  def change
    add_column :subtitle_files, :size, :integer
  end
end
