# frozen_string_literal: true

class AddSucceededAtToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :succeeded_at, :datetime
  end
end
