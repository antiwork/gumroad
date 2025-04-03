# frozen_string_literal: true

class AddWebhookUrlToLinks < ActiveRecord::Migration
  def change
    add_column :links, :webhook_url, :text
  end
end
