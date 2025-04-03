# frozen_string_literal: true

class CreateSentEmailInfos < ActiveRecord::Migration
  def change
    create_table :sent_email_infos do |t|
      t.string :key, limit: 40, null: false, index: { unique: true }
      t.timestamps null: false
    end
  end
end
