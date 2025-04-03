# frozen_string_literal: true

class CreatePreorderLinks < ActiveRecord::Migration
  def change
    create_table :preorder_links do |t|
      t.references :link
      t.string :state
      t.datetime :release_at
      t.string :url
      t.string :attachment_guid
      t.string :custom_filetype

      t.timestamps
    end
    add_index :preorder_links, :link_id
  end
end
