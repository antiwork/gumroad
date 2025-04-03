# frozen_string_literal: true

class AddMetaToLinksAndUsers < ActiveRecord::Migration
  def up
    add_column :links, :preview_meta, :string
    add_column :links, :attachment_meta, :string
    add_column :users, :profile_meta, :string
  end

  def down
    remove_column :links, :preview_meta
    remove_column :links, :attachment_meta
    remove_column :users, :profile_meta
  end
end
