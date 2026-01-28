# frozen_string_literal: true

class AddStateToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :state, :string
  end
end
