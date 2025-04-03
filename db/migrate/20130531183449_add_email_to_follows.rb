# frozen_string_literal: true

class AddEmailToFollows < ActiveRecord::Migration
  def change
    add_column :follows, :email, :string
  end
end
