# frozen_string_literal: true

class AddedCardBrandToBins < ActiveRecord::Migration
  def up
    add_column :bins, :card_brand, :string
  end

  def down
    remove_column :bins, :card_brand
  end
end
