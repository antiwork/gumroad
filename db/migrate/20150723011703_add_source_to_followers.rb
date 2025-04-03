# frozen_string_literal: true

class AddSourceToFollowers < ActiveRecord::Migration
  def change
    add_column :followers, :source, :string
    add_column :followers, :source_product_id, :integer
  end
end
