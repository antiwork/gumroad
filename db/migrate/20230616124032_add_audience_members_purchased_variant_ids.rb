# frozen_string_literal: true

class AddAudienceMembersPurchasedVariantIds < ActiveRecord::Migration[7.0]
  def up
    change_table :audience_members, bulk: true do |t|
      t.remove_index name: :idx_audience_on_seller_and_purchases_variants_ids
      t.index "`seller_id`, (cast(json_extract(`details`,_utf8mb4'$.purchases[*].variant_ids[*]') as unsigned array))", name: "idx_audience_on_seller_and_purchases_variants_ids"
    end
  end

  def down
    change_table :audience_members, bulk: true do |t|
      t.remove_index name: :idx_audience_on_seller_and_purchases_variants_ids
      t.index "`seller_id`, (cast(json_extract(`details`,_utf8mb4'$.purchases[*].variant_id') as unsigned array))", name: "idx_audience_on_seller_and_purchases_variants_ids"
    end
  end
end
