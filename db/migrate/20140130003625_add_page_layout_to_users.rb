# frozen_string_literal: true

class AddPageLayoutToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column(:users, :page_layout, :text)
  end
end
