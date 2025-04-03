# frozen_string_literal: true

class AddManagePagesToUsers < ActiveRecord::Migration
  def change
    add_column :users, :manage_pages, :boolean, default: false
  end
end
