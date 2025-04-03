# frozen_string_literal: true

class Default < ActiveRecord::Migration
  def up
    change_column_default(:links, :price, 1.00)
    change_column_default(:links, :length_of_exclusivity, 0)
    change_column_default(:links, :number_of_paid_downloads, 0)
    change_column_default(:links, :number_of_downloads, 0)
    change_column_default(:links, :download_limit, 0)
    change_column_default(:links, :number_of_views, 0)
    change_column_default(:links, :balance, 0.00)

    change_column_default(:users, :balance, 0.00)
  end

  def down
  end
end
