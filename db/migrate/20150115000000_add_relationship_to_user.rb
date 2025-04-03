# frozen_string_literal: true

class AddRelationshipToUser < ActiveRecord::Migration
  def change
    add_column :users, :relationship, :integer, default: 0
  end
end
