# frozen_string_literal: true

class CreatePurchaseWalletTypes < ActiveRecord::Migration[4.2]
  def change
    create_table :purchase_wallet_types do |t|
      t.references :purchase, index: { unique: true }, null: false
      t.string :wallet_type, index: true, null: false
    end
  end
end
