# frozen_string_literal: true

class RemoveOldProductTags < ActiveRecord::Migration
  def change
    drop_table :product_tags
  end
end
