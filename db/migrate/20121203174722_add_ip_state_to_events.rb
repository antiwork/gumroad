# frozen_string_literal: true

class AddIpStateToEvents < ActiveRecord::Migration[4.2]
  def change
    add_column :events, :ip_state, :string
  end
end
