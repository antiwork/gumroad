# frozen_string_literal: true

class RemoveAudienceMembersMultivaluedIndexes < ActiveRecord::Migration[7.0]
  def up
    change_table :audience_members, bulk: true do |t|
      t.remove_index name: :idx_audience_on_seller_and_purchases_countries
      t.remove_index name: :idx_audience_on_seller_and_purchases_products_ids
      t.remove_index name: :idx_audience_on_seller_and_purchases_variants_ids
    end
  end

  def down
    change_table :audience_members, bulk: true do |t|
      t.index "`seller_id`, (cast(json_extract(`details`,_utf8mb4'$.purchases[*].country') as char(100) array))", name: "idx_audience_on_seller_and_purchases_countries"
      t.index "`seller_id`, (cast(json_extract(`details`,_utf8mb4'$.purchases[*].product_id') as unsigned array))", name: "idx_audience_on_seller_and_purchases_products_ids"
      t.index "`seller_id`, (cast(json_extract(`details`,_utf8mb4'$.purchases[*].variant_ids[*]') as unsigned array))", name: "idx_audience_on_seller_and_purchases_variants_ids"
    end
  end
end
