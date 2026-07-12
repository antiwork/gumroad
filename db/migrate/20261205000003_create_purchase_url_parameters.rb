# frozen_string_literal: true

class CreatePurchaseUrlParameters < ActiveRecord::Migration[7.1]
  def change
    create_table :purchase_url_parameters do |t|
      t.references :purchase, index: { unique: true }, null: false
      t.json :params, null: false

      t.timestamps
    end
  end
end
