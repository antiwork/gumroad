# frozen_string_literal: true

class AddIpStateToEvents < ActiveRecord::Migration
  def change
    add_column :events, :ip_state, :string
  end
end
