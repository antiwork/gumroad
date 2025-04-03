# frozen_string_literal: true

class AddPreviewWidthToLink < ActiveRecord::Migration
  def change
    add_column :links, :preview_attachment_id, :integer
  end
end
