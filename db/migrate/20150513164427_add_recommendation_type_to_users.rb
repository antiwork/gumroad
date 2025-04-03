# frozen_string_literal: true

class AddRecommendationTypeToUsers < ActiveRecord::Migration
  def change
    add_column :users, :recommendation_type, :string, default: User::RecommendationType::SAME_CREATOR_PRODUCTS, null: false
  end
end
