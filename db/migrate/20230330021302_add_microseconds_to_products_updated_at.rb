# frozen_string_literal: true

class AddMicrosecondsToProductsUpdatedAt < ActiveRecord::Migration[7.0]
  def up
    change_column :links, :updated_at, :datetime, precision: 6
  end

  def down
    change_column :links, :updated_at, :datetime, precision: nil
  end
end
