# frozen_string_literal: true

class AddPreorderIdToCreditCards < ActiveRecord::Migration
  def change
    add_column :credit_cards, :preorder_id, :integer
    add_index :credit_cards, :preorder_id
  end
end
