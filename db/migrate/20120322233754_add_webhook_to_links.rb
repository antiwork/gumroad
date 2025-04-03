# frozen_string_literal: true

class AddWebhookToLinks < ActiveRecord::Migration
  def change
    add_column :links, :webhook, :boolean
  end
end
