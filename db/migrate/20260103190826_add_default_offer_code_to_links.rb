class AddDefaultOfferCodeToLinks < ActiveRecord::Migration[7.1]
  def change
    add_column :links, :default_offer_code_id, :bigint
    add_index :links, :default_offer_code_id
  end
end
