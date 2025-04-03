# frozen_string_literal: true

class AddBetterUrlRedirectsPostIndexes < ActiveRecord::Migration[7.0]
  def change
    change_table :url_redirects, bulk: true do |t|
      t.index [:installment_id, :purchase_id]
      t.index [:installment_id, :subscription_id]
      t.index [:installment_id, :imported_customer_id]
      t.remove_index :installment_id
    end
  end
end
