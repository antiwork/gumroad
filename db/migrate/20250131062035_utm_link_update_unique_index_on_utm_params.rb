# frozen_string_literal: true

class UtmLinkUpdateUniqueIndexOnUtmParams < ActiveRecord::Migration[7.1]
  def change
    change_table :utm_links, bulk: true do |t|
      t.remove_index [:seller_id, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content], where: "deleted_at IS NULL", name: "index_utm_links_on_utm_fields", unique: true
      t.index [:seller_id, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content, :target_resource_type, :target_resource_id], where: "deleted_at IS NULL", name: "index_utm_links_on_utm_fields_and_target_resource", unique: true
    end
  end
end
