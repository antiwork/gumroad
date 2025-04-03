# frozen_string_literal: true

class CreateThirdPartyAnalytics < ActiveRecord::Migration
  def change
    create_table :third_party_analytics, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.integer :user_id
      t.integer :link_id
      t.text :analytics_code
      t.integer :flags, default: 0, null: false
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :third_party_analytics, :link_id
    add_index :third_party_analytics, :user_id
  end
end
