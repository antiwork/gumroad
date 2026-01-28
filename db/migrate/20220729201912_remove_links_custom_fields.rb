# frozen_string_literal: true

class RemoveLinksCustomFields < ActiveRecord::Migration[4.2]
  def up
    remove_column :links, :custom_fields
  end

  def down
    add_column :links, :custom_fields, :text, size: :medium
  end
end
