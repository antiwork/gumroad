# frozen_string_literal: true

class AddAssetPreviews < ActiveRecord::Migration
  def change
    create_table :asset_previews, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.belongs_to :link
      t.attachment :attachment
      t.string     :guid
      t.text       :oembed
      t.timestamps
      t.datetime   :deleted_at
      t.index      :link_id
    end
  end
end
