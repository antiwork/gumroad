# frozen_string_literal: true

class RemoveUsersRecommendationTypeDefault < ActiveRecord::Migration[4.2]
  def up
    Alterity.disable do
      change_column_default :users, :recommendation_type, nil
    end
  end

  def down
    Alterity.disable do
      change_column_default :users, :recommendation_type, "same_creator_products"
    end
  end
end
