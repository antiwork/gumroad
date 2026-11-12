# frozen_string_literal: true

class CreateMetaConversionsSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :meta_conversions_settings do |t|
      t.bigint :user_id, null: false
      t.text :access_token, null: false
      t.datetime :token_rejected_at
      t.timestamps

      t.index :user_id, unique: true
    end
  end
end
