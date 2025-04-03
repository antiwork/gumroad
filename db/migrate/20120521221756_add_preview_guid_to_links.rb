# frozen_string_literal: true

class AddPreviewGuidToLinks < ActiveRecord::Migration
  def up
    add_column :links, :preview_guid, :string
  end

  def down
    remove_column :links, :preview_guid
  end
end
