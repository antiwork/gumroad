# frozen_string_literal: true

class AddDeletedAtToSubtitleFile < ActiveRecord::Migration[4.2]
  def change
    add_column :subtitle_files, :deleted_at, :datetime
  end
end
