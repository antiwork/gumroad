# frozen_string_literal: true

class AddMegaphoneStatesDatetimes < ActiveRecord::Migration
  def change
    add_column :megaphone_states, :created_at, :datetime
    add_column :megaphone_states, :updated_at, :datetime
  end
end
