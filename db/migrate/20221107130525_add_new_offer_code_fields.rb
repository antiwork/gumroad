# frozen_string_literal: true

class AddNewOfferCodeFields < ActiveRecord::Migration[7.0]
  def change
    change_table :offer_codes, bulk: true do |t|
      t.string :code
      t.boolean :universal, default: false, null: false

      t.index [:code, :link_id], name: "index_offer_codes_on_code_and_link_id", length: { name: 191 }
      t.index [:universal], name: "index_offer_codes_on_universal"
    end
  end
end
