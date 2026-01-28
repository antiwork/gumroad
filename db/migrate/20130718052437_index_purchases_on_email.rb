# frozen_string_literal: true

class IndexPurchasesOnEmail < ActiveRecord::Migration[4.2]
  def change
    add_index :purchases, :email, length: 10
  end
end
