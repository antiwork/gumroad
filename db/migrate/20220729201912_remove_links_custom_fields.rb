# frozen_string_literal: true

class RemoveLinksCustomFields < ActiveRecord::Migration[6.1]
  def up
    remove_column :links, :custom_fields
  end

  def down
    add_column :links, :custom_fields, :text, size: :medium
  end
end
