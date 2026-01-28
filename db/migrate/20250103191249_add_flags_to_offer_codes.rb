# frozen_string_literal: true

class AddFlagsToOfferCodes < ActiveRecord::Migration[4.2]
  def change
    add_column :offer_codes, :flags, :bigint, default: 0, null: false
  end
end
