# frozen_string_literal: true

class AddDefaultToPreviewProcessed < ActiveRecord::Migration
  def up
    change_column :links, :preview_processed, :boolean, default: true
  end

  def down
    change_column :links, :preview_processed, :boolean, default: nil
  end
end
