# frozen_string_literal: true

class AddTrackingUrlToShipments < ActiveRecord::Migration
  def change
    add_column :shipments, :tracking_url, :string, limit: 2083
  end
end
