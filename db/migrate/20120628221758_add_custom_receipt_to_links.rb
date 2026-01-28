# frozen_string_literal: true

class AddCustomReceiptToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :custom_receipt, :text
  end
end
