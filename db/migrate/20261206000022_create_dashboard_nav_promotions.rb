# frozen_string_literal: true

class CreateDashboardNavPromotions < ActiveRecord::Migration[7.1]
  def change
    create_table :dashboard_nav_promotions do |t|
      t.bigint :user_id, null: false
      t.string :nav_item, null: false

      t.timestamps

      t.index [:user_id, :nav_item], unique: true
    end
  end
end
