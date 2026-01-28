# frozen_string_literal: true

class AddEmailToFollows < ActiveRecord::Migration[4.2]
  def change
    add_column :follows, :email, :string
  end
end
