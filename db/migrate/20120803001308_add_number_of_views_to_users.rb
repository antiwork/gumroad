# frozen_string_literal: true

class AddNumberOfViewsToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :number_of_views, :integer
  end
end
