# frozen_string_literal: true

class AddWebhookFailCountToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :webhook_fail_count, :integer
  end
end
