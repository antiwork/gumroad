# frozen_string_literal: true

class AddWebhookToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :webhook, :boolean
  end
end
