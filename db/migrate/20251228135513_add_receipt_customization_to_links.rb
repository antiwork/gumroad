# frozen_string_literal: true

class AddReceiptCustomizationToLinks < ActiveRecord::Migration[7.2]
  def change
    add_column :links, :receipt_custom_text, :text
    add_column :links, :receipt_button_text, :string, limit: 50
  end
end
