# frozen_string_literal: true

class AddStateToUsers < ActiveRecord::Migration
  def change
    add_column :users, :state, :string
  end
end
