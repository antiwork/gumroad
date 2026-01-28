# frozen_string_literal: true

class AddChargebackedPurchaseIdToCredits < ActiveRecord::Migration[4.2]
  def change
    add_column :credits, :chargebacked_purchase_id, :integer
  end
end
