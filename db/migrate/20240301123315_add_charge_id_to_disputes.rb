# frozen_string_literal: true

class AddChargeIdToDisputes < ActiveRecord::Migration[7.1]
  def change
    add_reference :disputes, :charge, index: true
  end
end
