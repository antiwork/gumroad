# frozen_string_literal: true

class RemoveRichContentVersionFromLinks < ActiveRecord::Migration[7.1]
  def up
    remove_column :links, :rich_content_version
  end

  def down
    add_column :links, :rich_content_version, :integer, default: 1
  end
end
