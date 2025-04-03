# frozen_string_literal: true

class AddProductToCustomDomains < ActiveRecord::Migration[7.0]
  def change
    change_table :custom_domains, bulk: true do |t|
      t.references :product, index: true
    end
  end
end
