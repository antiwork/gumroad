# frozen_string_literal: true

class AddVariantsToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :variants, :text
  end
end
