# frozen_string_literal: true

class AddWebhookFailCountToLinks < ActiveRecord::Migration
  def change
    add_column :links, :webhook_fail_count, :integer
  end
end
