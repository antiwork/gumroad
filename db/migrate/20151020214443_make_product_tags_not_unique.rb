# frozen_string_literal: true

class MakeProductTagsNotUnique < ActiveRecord::Migration[4.2]
  def change
    remove_index :product_tags, [:link_id, :tag]
    add_index :product_tags, [:link_id, :tag]
  end
end
