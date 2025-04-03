# frozen_string_literal: true

class IncreaseUtmLinkParamCharLimits < ActiveRecord::Migration[7.1]
  def up
    change_table :utm_links, bulk: true do |t|
      t.remove_index name: "index_utm_links_on_utm_fields_and_target_resource"

      t.change :utm_campaign, :string, limit: 200
      t.change :utm_medium, :string, limit: 200
      t.change :utm_source, :string, limit: 200
      t.change :utm_term, :string, limit: 200
      t.change :utm_content, :string, limit: 200

      t.index [:seller_id, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content, :target_resource_type, :target_resource_id], where: "deleted_at IS NULL", name: "index_utm_links_on_utm_fields_and_target_resource", unique: true, length: { utm_campaign: 100, utm_medium: 100, utm_source: 100, utm_term: 100, utm_content: 100 }
    end
  end

  def down
    change_table :utm_links, bulk: true do |t|
      t.remove_index name: "index_utm_links_on_utm_fields_and_target_resource"

      t.change :utm_campaign, :string, limit: 64
      t.change :utm_medium, :string, limit: 64
      t.change :utm_source, :string, limit: 64
      t.change :utm_term, :string, limit: 64
      t.change :utm_content, :string, limit: 64

      t.index [:seller_id, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content, :target_resource_type, :target_resource_id], where: "deleted_at IS NULL", name: "index_utm_links_on_utm_fields_and_target_resource", unique: true
    end
  end
end
