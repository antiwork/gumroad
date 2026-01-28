# frozen_string_literal: true

class AddChargeIdToDisputes < ActiveRecord::Migration[4.2]
  def change
    add_reference :disputes, :charge, index: true
  end
end
