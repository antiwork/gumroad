# frozen_string_literal: true

class CreateOrders < ActiveRecord::Migration[4.2]
  def change
    create_table :orders do |t|
      t.references :purchaser

      t.timestamps
    end
  end
end
