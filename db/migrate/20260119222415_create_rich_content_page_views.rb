# frozen_string_literal: true

class CreateRichContentPageViews < ActiveRecord::Migration[7.1]
  def change
    create_table :rich_content_page_views do |t|
      t.bigint :rich_content_id, null: false
      t.bigint :purchase_id, null: false
      t.bigint :product_id, null: false
      t.bigint :buyer_id
      t.string :url_redirect_id, limit: 191
      t.string :ip_address, limit: 191
      t.string :user_agent, limit: 500
      t.datetime :viewed_at, null: false

      t.timestamps

      t.index :rich_content_id
      t.index :purchase_id
      t.index :product_id
      t.index [:product_id, :viewed_at]
      t.index [:rich_content_id, :viewed_at]
    end
  end
end
