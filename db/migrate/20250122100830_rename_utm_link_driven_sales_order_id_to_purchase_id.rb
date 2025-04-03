# frozen_string_literal: true

class RenameUtmLinkDrivenSalesOrderIdToPurchaseId < ActiveRecord::Migration[7.1]
  def change
    change_table :utm_link_driven_sales, bulk: true do |t|
      t.remove_index [:utm_link_visit_id, :order_id], unique: true
      t.remove_index :order_id
      t.rename :order_id, :purchase_id
      t.index [:utm_link_visit_id, :purchase_id], unique: true
      t.index :purchase_id
    end
  end
end
