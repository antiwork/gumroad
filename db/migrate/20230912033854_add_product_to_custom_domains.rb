# frozen_string_literal: true

class AddProductToCustomDomains < ActiveRecord::Migration[4.2]
  def change
    change_table :custom_domains, bulk: true do |t|
      t.references :product, index: true
    end
  end
end
