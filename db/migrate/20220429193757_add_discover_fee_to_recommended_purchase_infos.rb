# frozen_string_literal: true

class AddDiscoverFeeToRecommendedPurchaseInfos < ActiveRecord::Migration[6.1]
  def change
    add_column :recommended_purchase_infos, :discover_fee_per_thousand, :integer
  end
end
