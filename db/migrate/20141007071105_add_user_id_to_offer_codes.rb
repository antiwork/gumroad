# frozen_string_literal: true

class AddUserIdToOfferCodes < ActiveRecord::Migration[4.2]
  def change
    add_column :offer_codes, :user_id, :integer
    add_index :offer_codes, [:user_id], name: "index_offer_codes_on_user_id"
  end
end
