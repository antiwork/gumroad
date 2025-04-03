# frozen_string_literal: true

class AddRecommenderModelNameToRecommendedPurchaseInfos < ActiveRecord::Migration[7.0]
  def change
    add_column :recommended_purchase_infos, :recommender_model_name, :string
  end
end
