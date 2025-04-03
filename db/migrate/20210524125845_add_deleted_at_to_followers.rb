# frozen_string_literal: true

class AddDeletedAtToFollowers < ActiveRecord::Migration[6.1]
  def change
    add_column :followers, :deleted_at, :datetime, null: true
  end
end
