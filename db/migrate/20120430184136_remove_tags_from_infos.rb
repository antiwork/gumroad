# frozen_string_literal: true

class RemoveTagsFromInfos < ActiveRecord::Migration[4.2]
  def up
    remove_column :infos, :tags
  end

  def down
    add_column :infos, :tags, :string
  end
end
