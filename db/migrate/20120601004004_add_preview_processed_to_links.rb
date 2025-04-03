# frozen_string_literal: true

class AddPreviewProcessedToLinks < ActiveRecord::Migration
  def change
    add_column :links, :preview_processed, :boolean
  end
end
