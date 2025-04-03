# frozen_string_literal: true

class RemoveAuthorFromInfos < ActiveRecord::Migration
  def up
    remove_column :infos, :author
  end

  def down
    add_column :infos, :author, :string
  end
end
