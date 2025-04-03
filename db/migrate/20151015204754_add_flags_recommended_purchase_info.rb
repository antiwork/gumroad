# frozen_string_literal: true

class AddFlagsRecommendedPurchaseInfo < ActiveRecord::Migration
  def change
    add_column :recommended_purchase_infos, :flags, :integer, default: 0, null: false
  end
end
