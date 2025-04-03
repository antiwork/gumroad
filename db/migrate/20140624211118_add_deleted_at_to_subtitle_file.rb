# frozen_string_literal: true

class AddDeletedAtToSubtitleFile < ActiveRecord::Migration
  def change
    add_column :subtitle_files, :deleted_at, :datetime
  end
end
