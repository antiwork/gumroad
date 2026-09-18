# frozen_string_literal: true

class AddReconnectNotifiedAtToMarketingActions < ActiveRecord::Migration[7.1]
  def change
    add_column :marketing_actions, :reconnect_notified_at, :datetime
  end
end
