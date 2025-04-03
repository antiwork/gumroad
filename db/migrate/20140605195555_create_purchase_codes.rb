# frozen_string_literal: true

class CreatePurchaseCodes < ActiveRecord::Migration
  def change
    create_table :purchase_codes, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_general_ci" do |t|
      t.string :token
      t.datetime :used_at
      t.datetime :expires_at
      t.integer :url_redirect_id

      t.timestamps
    end

    add_index :purchase_codes, :token
    add_index :purchase_codes, :url_redirect_id
  end
end
