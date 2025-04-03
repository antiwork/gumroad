# frozen_string_literal: true

class CreateUtmLinkDrivenSales < ActiveRecord::Migration[7.1]
  def change
    create_table :utm_link_driven_sales do |t|
      t.references :utm_link, null: false
      t.references :utm_link_visit, null: false
      t.references :order, null: false
      t.timestamps

      t.index [:utm_link_visit_id, :order_id], unique: true
    end
  end
end
