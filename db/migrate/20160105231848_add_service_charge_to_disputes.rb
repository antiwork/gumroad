# frozen_string_literal: true

class AddServiceChargeToDisputes < ActiveRecord::Migration
  def change
    add_column  :disputes, :service_charge_id, :integer
    add_index   :disputes, :service_charge_id
  end
end
