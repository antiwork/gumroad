# frozen_string_literal: true

class AddTrackingNumberAndCarrierToShipment < ActiveRecord::Migration
  def change
    add_column :shipments, :tracking_number, :string
    add_column :shipments, :carrier, :string
  end
end
