# frozen_string_literal: true

class IndexPurchasesOnOfferCodeId < ActiveRecord::Migration
  def change
    add_index :purchases, :offer_code_id
  end
end
