# frozen_string_literal: true

class AllowEmailToBeNil < ActiveRecord::Migration
  def up
    change_column :users, :email, :string, allow_nil: true
  end

  def down
    change_column :users, :email, :string, allow_nil: false
  end
end
