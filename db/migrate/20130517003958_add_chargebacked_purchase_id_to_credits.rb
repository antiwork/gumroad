# frozen_string_literal: true

class AddChargebackedPurchaseIdToCredits < ActiveRecord::Migration
  def change
    add_column :credits, :chargebacked_purchase_id, :integer
  end
end
