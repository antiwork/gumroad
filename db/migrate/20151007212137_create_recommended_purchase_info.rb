# frozen_string_literal: true

class CreateRecommendedPurchaseInfo < ActiveRecord::Migration
  def change
    create_table :recommended_purchase_infos, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.timestamps

      t.references  :purchase
      t.integer     :recommended_link_id
      t.integer     :recommended_by_link_id
      t.string      :recommendation_type
    end

    add_index :recommended_purchase_infos, :purchase_id
    add_index :recommended_purchase_infos, :recommended_link_id
    add_index :recommended_purchase_infos, :recommended_by_link_id
  end
end
