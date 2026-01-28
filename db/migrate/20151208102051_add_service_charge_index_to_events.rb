# frozen_string_literal: true

class AddServiceChargeIndexToEvents < ActiveRecord::Migration[4.2]
  def change
    add_index :events, :service_charge_id
  end
end
