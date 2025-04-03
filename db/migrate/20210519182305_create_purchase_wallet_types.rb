# frozen_string_literal: true

class CreatePurchaseWalletTypes < ActiveRecord::Migration[6.1]
  def change
    create_table :purchase_wallet_types do |t|
      t.references :purchase, index: { unique: true }, null: false
      t.string :wallet_type, index: true, null: false
    end
  end
end
