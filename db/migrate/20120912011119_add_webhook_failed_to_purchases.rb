# frozen_string_literal: true

class AddWebhookFailedToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :webhook_failed, :boolean, default: false
  end
end
