# frozen_string_literal: true

class AddRichContentVersionToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :rich_content_version, :integer, default: 0
  end
end
