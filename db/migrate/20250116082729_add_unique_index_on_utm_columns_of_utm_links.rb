# frozen_string_literal: true

class AddUniqueIndexOnUtmColumnsOfUtmLinks < ActiveRecord::Migration[7.1]
  def up
    change_table :utm_links, bulk: true do |t|
      t.change :utm_source, :string, limit: 64, null: false
      t.change :utm_medium, :string, limit: 64, null: false
      t.change :utm_campaign, :string, limit: 64, null: false
      t.change :utm_term, :string, limit: 64
      t.change :utm_content, :string, limit: 64
      t.index [:seller_id, :utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content], unique: true, where: "deleted_at IS NULL", name: "index_utm_links_on_utm_fields"
    end
  end

  def down
    change_table :utm_links, bulk: true do |t|
      t.change :utm_source, :string, limit: nil, null: true
      t.change :utm_medium, :string, limit: nil, null: false
      t.change :utm_campaign, :string, limit: nil, null: false
      t.change :utm_term, :string, limit: nil
      t.change :utm_content, :string, limit: nil
      t.remove_index name: "index_utm_links_on_utm_fields"
    end
  end
end
