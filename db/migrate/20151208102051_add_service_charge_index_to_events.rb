# frozen_string_literal: true

class AddServiceChargeIndexToEvents < ActiveRecord::Migration
  def change
    add_index :events, :service_charge_id
  end
end
