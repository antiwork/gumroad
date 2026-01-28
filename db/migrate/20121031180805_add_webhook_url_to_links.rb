# frozen_string_literal: true

class AddWebhookUrlToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :webhook_url, :text
  end
end
