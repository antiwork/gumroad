# frozen_string_literal: true

class LinksMissingAttr < ActiveRecord::Migration[7.1]
  def up
    add_column :links, :owner, :string
    add_column :links, :length_of_exclusivity, :integer
    add_column :links, :create_date, :integer
  end

  def down
    remove_column :links, :owner
    remove_column :links, :length_of_exclusivity
    remove_column :links, :create_date
  end
end
