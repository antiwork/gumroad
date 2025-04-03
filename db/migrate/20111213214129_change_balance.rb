# frozen_string_literal: true

class ChangeBalance < ActiveRecord::Migration
  def up
    add_column :links, :balance_cents, :integer
    Link.find_each do |link|
      link.balance_cents = link.balance * 100
      link.save(validation: false)
    end
  end

  def down
    remove_column :links, :balance_cents
  end
end
