# frozen_string_literal: true

class AddVariantsToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :variants, :text
  end
end
