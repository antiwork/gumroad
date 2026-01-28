# frozen_string_literal: true

class AddPreviewWidthToLink < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :preview_attachment_id, :integer
  end
end
