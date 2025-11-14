# frozen_string_literal: true

class AddRichContentTrackingToConsumptionEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :consumption_events, :rich_content_id, :bigint
    add_column :consumption_events, :content_page_index, :integer

    add_index :consumption_events, :rich_content_id
    add_index :consumption_events, [:rich_content_id, :content_page_index], name: "index_consumption_events_on_rich_content_and_page"
  end
end
