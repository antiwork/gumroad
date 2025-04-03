# frozen_string_literal: true

class AddDefaultValueToWebhookFailCount < ActiveRecord::Migration
  def up
    change_column :links, :webhook_fail_count, :integer, default: 0
  end

  def down
    change_column :links, :webhook_fail_count, :integer, default: nil
  end
end
