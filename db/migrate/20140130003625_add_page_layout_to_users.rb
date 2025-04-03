# frozen_string_literal: true

class AddPageLayoutToUsers < ActiveRecord::Migration
  def change
    add_column(:users, :page_layout, :text)
  end
end
