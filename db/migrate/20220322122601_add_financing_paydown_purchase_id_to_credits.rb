# frozen_string_literal: true

class AddFinancingPaydownPurchaseIdToCredits < ActiveRecord::Migration[4.2]
  def change
    add_column :credits, :financing_paydown_purchase_id, :integer
  end
end
