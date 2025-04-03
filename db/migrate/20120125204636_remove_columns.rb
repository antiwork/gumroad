# frozen_string_literal: true

class RemoveColumns < ActiveRecord::Migration
  def up
    remove_column :users, :create_date
    remove_column :purchases, :create_date
    remove_column :links, :create_date

    remove_column :purchases, :owner
    remove_column :links, :owner

    remove_column :links, :length_of_exclusivity
    remove_column :links, :number_of_downloads
    remove_column :links, :download_limit
  end

  def down
    add_column :links, :create_date, :int
    add_column :purchases, :create_date, :int
    add_column :users, :create_date, :int

    add_column :purchases, :owner
    Purchase.each do |purchase|
      purchase.owner = purchase.user.email
      purchase.save
    end

    add_column :links, :owner
    Link.each do |link|
      link.owner = link.user.email
      link.save
    end

    remove_column :links, :length_of_exclusivity, :integer, default: 0
    remove_column :links, :number_of_downloads, :integer, default: 0
    remove_column :links, :download_limit, :integer, default: 0
  end
end
