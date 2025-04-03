# frozen_string_literal: true

class RemoveLegacyUrlAndWebhookColumnsFromLinks < ActiveRecord::Migration[7.0]
  def up
    change_table :links, bulk: true do |t|
      t.remove :url
      t.remove :webhook
      t.remove :webhook_url
    end
  end

  def down
    change_table :links, bulk: true do |t|
      t.column :url, :mediumtext
      t.column :webhook, :boolean, default: false
      t.column :webhook_url, :mediumtext
    end
  end
end
