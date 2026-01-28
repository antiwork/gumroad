# frozen_string_literal: true

class AddSizeToSubtitleFiles < ActiveRecord::Migration[4.2]
  def change
    add_column :subtitle_files, :size, :integer
  end
end
