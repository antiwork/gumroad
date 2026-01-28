# frozen_string_literal: true

class AddRelationshipToUser < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :relationship, :integer, default: 0
  end
end
