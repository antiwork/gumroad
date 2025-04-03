# frozen_string_literal: true

class AddTagsToInfos < ActiveRecord::Migration
  def change
    add_column :infos, :tags, :string
  end
end
