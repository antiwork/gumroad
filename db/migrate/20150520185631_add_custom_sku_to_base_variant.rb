# frozen_string_literal: true

class AddCustomSkuToBaseVariant < ActiveRecord::Migration
  def change
    add_column :base_variants, :custom_sku, :string
  end
end
