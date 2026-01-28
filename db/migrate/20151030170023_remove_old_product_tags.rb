# frozen_string_literal: true

class RemoveOldProductTags < ActiveRecord::Migration[4.2]
  def change
    drop_table :product_tags
  end
end
